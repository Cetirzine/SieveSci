import Foundation

// MARK: - Citation verification (available to every role)

/// Checks a reference online: it exists, its metadata matches what is cited, it is not retracted,
/// and its text contains passages relevant to the statement it is cited for (PaperQA2-style
/// evidence gathering, lexical). The agent judges support from the returned passages.
struct VerifyCitationTool: Tool {
    let name = "verify_citation"
    let description = """
    Verify a citation online: resolve a library key, DOI, PMID or arXiv id; check the paper exists, its \
    title/authors/year, and whether it is retracted or has an expression of concern; and return the passages \
    most relevant to the statement it is cited for. Use it before relying on a citation and when reviewing.
    """
    var inputSchema: JSON {
        Schema.object(["ref": Schema.string("Library key, DOI, PMID or arXiv id"),
                       "claim": Schema.string("The statement the paper is cited for"),
                       "expected_title": Schema.string("Title as cited (optional, to detect mismatches)"),
                       "expected_year": Schema.integer("Year as cited (optional)")], required: ["claim", "ref"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let lib = ctx.services.library
        let raw = try input.required("ref")
        var rec = lib.find(raw) ?? lib.find(PaperRef.normalize(raw).1)
        var notes: [String] = []
        if rec == nil {
            let (kind, id) = PaperRef.normalize(raw)
            let q: String
            switch kind {
            case .doi: q = "DOI:\"\(id)\""
            case .pmid: q = "EXT_ID:\(id) AND SRC:MED"
            case .pmcid: q = "PMCID:\(id)"
            default: q = id
            }
            if kind == .arxiv { rec = try? await lib.searchArXiv("id:\(id)", limit: 1).first }
            else { rec = try? await lib.searchEuropePMC(q, limit: 1).first }
            if rec == nil, kind == .doi { rec = try? await lib.crossref(doi: id) }
            guard let found = rec else { return .error("NOT FOUND: \(raw) does not resolve in Europe PMC, Crossref or arXiv. Treat the citation as unverified.") }
            rec = lib.add(found)
            notes.append("added to library as [@\(rec!.key)]")
        }
        guard var r = rec else { return .error("unresolved") }
        if r.textPath == nil { r = (try? await lib.download(r.key)) ?? r }

        // Retraction / concern status from Europe PMC publication types.
        var status = "no retraction or expression of concern found"
        if let doi = r.doi ?? r.pmid {
            let q = r.doi != nil ? "DOI:\"\(doi)\"" : "EXT_ID:\(doi) AND SRC:MED"
            if let j = try? await lib.get("https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=\(LiteratureLibrary.q(q))&format=json&resultType=core&pageSize=1"),
               let types = j["resultList"]?["result"]?[0]?["pubTypeList"]?["pubType"]?.arrayValue?.compactMap(\.stringValue) {
                if types.contains(where: { $0.localizedCaseInsensitiveContains("retracted") }) { status = "⚠ RETRACTED PUBLICATION — do not rely on it" }
                else if types.contains(where: { $0.localizedCaseInsensitiveContains("concern") }) { status = "⚠ expression of concern" }
            }
        }

        // Metadata match against what was cited.
        if let t = input.str("expected_title"), !t.isEmpty {
            let a = Set(RoleModelAdvisor.normalize(t).chunked(4)), b = Set(RoleModelAdvisor.normalize(r.title).chunked(4))
            let overlap = Double(a.intersection(b).count) / Double(max(1, a.count))
            if overlap < 0.6 { notes.append("⚠ cited title does not match the record (\(Int(overlap * 100))% overlap): “\(r.title)”") }
        }
        if let y = input.int("expected_year"), let ry = r.year, abs(y - ry) > 1 { notes.append("⚠ cited year \(y) vs record \(ry)") }

        // Passages relevant to the claim.
        let claim = try input.required("claim")
        var passages = "No text available beyond metadata."
        if let text = lib.text(r.key) {
            let terms = claim.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 3 }
            let paras = text.components(separatedBy: "\n\n").filter { $0.count > 80 }
            let ranked = paras.map { p -> (String, Int) in (p, terms.reduce(0) { $0 + (p.lowercased().contains($1) ? 1 : 0) }) }
                .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.prefix(4)
            passages = ranked.isEmpty ? "No passage shares key terms with the claim — the paper may not support it." :
                ranked.map { "> " + $0.0.truncated(900, marker: "…") }.joined(separator: "\n\n")
            if text.hasPrefix("[abstract only") { notes.append("only the abstract is available (no open-access full text)") }
        }
        let flagged = status.hasPrefix("⚠") || notes.contains { $0.hasPrefix("⚠") }
        ctx.services.emit(.literature(agentId: ctx.sessionId, action: flagged ? .flagged : .verified, key: r.key, title: r.title,
                                      detail: ([status] + notes).joined(separator: " · ")))
        return ToolOutput("""
        [@\(r.key)] \(r.title) — \(r.authors.prefix(4).joined(separator: ", "))\(r.authors.count > 4 ? " et al." : "") (\(r.year.map(String.init) ?? "n.d."), \(r.venue ?? r.source))
        DOI \(r.doi ?? "-") · PMID \(r.pmid ?? "-") · status: \(status)
        \(notes.joined(separator: "\n"))
        Passages relevant to: “\(claim.truncated(300))”
        \(passages)
        Judge whether these passages support the claim; if they do not, say so.
        """, facts: ["paper": .string(r.key)])
    }
}

extension String {
    /// Character n-grams for fuzzy title comparison.
    func chunked(_ n: Int) -> [String] {
        let a = Array(self)
        guard a.count >= n else { return [self] }
        return (0...(a.count - n)).map { String(a[$0..<($0 + n)]) }
    }
}

// MARK: - Batch dispatch (subagent workflows)

/// Fans a task template out over many items with worker subagents — systematic-review screening,
/// per-sample QC, per-compound property lookups, extracting a table from 50 papers — or ranks items
/// by pairwise comparison (Robin's tournament-style candidate ranking).
///
/// Cache-aware: the shared template comes first in every worker's message and the item last, all
/// workers share the frozen worker prefix, and the first worker runs alone until its request has
/// written the cache; the rest then read it (concurrent requests cannot read an entry still being
/// written). Results are written to `<task>/dispatch/<label>.jsonl` with receipts per item.
struct DispatchTool: Tool {
    let name = "dispatch"
    let description = """
    Run a batch workflow with worker subagents. mode "map": apply the instructions to each item in parallel and \
    collect per-item results (e.g. screen 80 abstracts against inclusion criteria, extract effect sizes from 30 \
    papers). mode "rank": compare items pairwise against a criterion and return a Bradley–Terry ranking with confidence intervals (e.g. \
    rank 12 candidate hypotheses or drug candidates). mode "consensus": run the same analysis (items[0]) in N independent \
    trajectories and report where they agree and disagree (Robin's multi-trajectory analysis). Every worker \
    follows the integrity rules; results go to a JSONL file.
    """
    var inputSchema: JSON {
        Schema.object(["label": Schema.string("Short name for this batch"),
                       "mode": Schema.stringEnum("map | rank | consensus", ["map", "rank", "consensus"]),
                       "trajectories": Schema.integer("consensus: independent runs (default 3, max 8)"),
                       "instructions": Schema.string("What to do per item (map) or the comparison criterion (rank)"),
                       "items": Schema.array("Items (strings: text, ids, file paths)", items: ["type": "string"]),
                       "max_parallel": Schema.integer("Concurrent workers (default 4, max 8)"),
                       "comparisons": Schema.integer("rank: pairwise comparisons (default 3 × items)")],
                      required: ["instructions", "items", "label", "mode"])
    }
    /// Workers may run code, so a batch is approved like running code (once for the whole batch).
    func effect(for input: JSON) -> ToolEffect { .executes }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.role == .main else { return .error("Only the main agent dispatches batches.") }
        let items = input["items"]?.arrayValue?.compactMap(\.stringValue) ?? []
        guard !items.isEmpty else { return .error("no items") }
        guard items.count <= 400 else { return .error("At most 400 items per batch; split it.") }
        let label = (try input.required("label")).replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
        let instructions = try input.required("instructions")
        let par = max(1, min(8, input.int("max_parallel") ?? 4))
        let out = ctx.services.taskDir.appendingPathComponent("dispatch/\(label).jsonl")
        try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)

        if input.str("mode") == "consensus" {
            return try await consensus(task: items[0], instructions: instructions, label: label, n: max(2, min(8, input.int("trajectories") ?? 3)),
                                       par: par, out: out, ctx: ctx)
        }
        if input.str("mode") == "rank" {
            return try await rank(items: items, criterion: instructions, comparisons: input.int("comparisons") ?? items.count * 3, par: par, out: out, ctx: ctx)
        }
        let header = "<batch label=\"\(label)\">\nInstructions (same for every item):\n\(instructions)\n</batch>\n"
        let results = await runPool(count: items.count, par: par) { i in
            let w = ctx.services.makeSubagent(role: .worker, purpose: "\(label) · item \(i + 1)/\(items.count)")
            let reply = (try? await w.send(header + "\n<item index=\"\(i + 1)\">\n\(items[i])\n</item>\nReturn the result for this item only.")?.plainText) ?? "(worker failed)"
            return reply
        }
        let enc = JSONEncoder()
        var lines: [String] = []
        for (i, r) in results.enumerated() {
            let row: JSON = ["index": .int(i + 1), "item": .string(items[i]), "result": .string(r)]
            lines.append(String(decoding: (try? enc.encode(row)) ?? Data(), as: UTF8.self))
        }
        try lines.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        let preview = results.enumerated().prefix(40).map { "\($0.offset + 1). \(items[$0.offset].truncated(80, marker: "…")) → \($0.element.truncated(300, marker: "…"))" }
        return ToolOutput("Batch \(label): \(items.count) items processed with up to \(par) workers. Full results: \(out.path)\n\n" + preview.joined(separator: "\n"),
                          filesWritten: [out.path])
    }

    /// Runs `count` jobs with at most `par` in flight; the first job runs alone to warm the cache.
    func runPool(count: Int, par: Int, _ job: @escaping @Sendable (Int) async -> String) async -> [String] {
        var results = [String](repeating: "", count: count)
        guard count > 0 else { return results }
        results[0] = await job(0)
        var next = 1
        await withTaskGroup(of: (Int, String).self) { g in
            func launch() { if next < count { let i = next; next += 1; g.addTask { (i, await job(i)) } } }
            for _ in 0..<par { launch() }
            for await (i, r) in g { results[i] = r; launch() }
        }
        return results
    }

    /// Robin-style multi-trajectory analysis: N independent workers, then agreement per result.
    func consensus(task: String, instructions: String, label: String, n: Int, par: Int, out: URL, ctx: ToolContext) async throws -> ToolOutput {
        let prompt = "<analysis>\n\(instructions)\n</analysis>\n\(task)\nWork independently. End with one JSON object: {\"results\": {\"name\": value, ...}, \"conclusion\": \"...\"}"
        let runs = await runPool(count: n, par: par) { i in
            let w = ctx.services.makeSubagent(role: .worker, purpose: "\(label) · independent trajectory \(i + 1)/\(n)")
            return (try? await w.send(prompt)?.plainText) ?? ""
        }
        var table: [String: [String]] = [:]
        for r in runs {
            for (k, v) in Supervisor.parseJSON(r)?["results"]?.objectValue ?? [:] { table[k, default: []].append(v.canonical) }
        }
        var lines: [String] = []
        for (k, vs) in table.sorted(by: { $0.key < $1.key }) {
            let agree = Set(vs).count == 1 && vs.count == n
            lines.append("\(k): \(vs.joined(separator: " | "))  \(agree ? "✓ all agree" : "⚠ differs")")
        }
        var conclusions: [String] = []
        for (i, r) in runs.enumerated() {
            conclusions.append("\(i + 1). " + (Supervisor.parseJSON(r)?.str("conclusion") ?? String(r.suffix(300))))
        }
        var jsonl: [String] = []
        for (i, r) in runs.enumerated() { jsonl.append("{\"trajectory\":\(i + 1),\"report\":\(JSON.string(r).canonical)}") }
        try jsonl.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return ToolOutput("Consensus over \(n) independent trajectories (reports: \(out.path)):\n"
                          + (lines.isEmpty ? "(no structured results returned)" : lines.joined(separator: "\n"))
                          + "\n\nConclusions:\n" + conclusions.joined(separator: "\n"), filesWritten: [out.path])
    }

    func rank(items: [String], criterion: String, comparisons: Int, par: Int, out: URL, ctx: ToolContext) async throws -> ToolOutput {
        var rng = SystemRandomNumberGenerator()
        let pairs = BradleyTerry.schedule(items: items.count, comparisons: min(comparisons, 600), using: &rng)
        let header = "<comparison>\nCriterion: \(criterion)\nCompare the two candidates strictly on the criterion and the evidence available. Search if needed. Answer with JSON only: {\"winner\": \"A\" | \"B\", \"reason\": \"...\"}\n</comparison>\n"
        let verdicts = await runPool(count: pairs.count, par: par) { k in
            let (a, b) = pairs[k]
            let w = ctx.services.makeSubagent(role: .worker, purpose: "rank: comparison \(k + 1)/\(pairs.count)")
            return (try? await w.send(header + "\nA:\n\(items[a])\n\nB:\n\(items[b])")?.plainText) ?? ""
        }
        var outcomes: [(winner: Int, loser: Int)] = []
        var log: [String] = []
        var firstWins = 0, unusable = 0
        for (k, v) in verdicts.enumerated() {
            let (a, b) = pairs[k]
            guard let j = Supervisor.parseJSON(v), let win = j.str("winner"), win == "A" || win == "B" else { unusable += 1; continue }
            outcomes.append(win == "A" ? (a, b) : (b, a))
            if win == "A" { firstWins += 1 }
            log.append("{\"a\":\(a + 1),\"b\":\(b + 1),\"winner\":\"\(win)\",\"reason\":\(JSON.string(j.str("reason") ?? "").canonical)}")
        }
        try log.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        return ToolOutput(Self.rankReport(items: items, outcomes: outcomes, planned: pairs.count, unusable: unusable, firstWins: firstWins, log: out.path),
                          filesWritten: [out.path])
    }

    static func rankReport(items: [String], outcomes: [(winner: Int, loser: Int)], planned: Int, unusable: Int, firstWins: Int, log: String) -> String {
        let scores = BradleyTerry.fit(items: items.count, outcomes: outcomes).sorted { $0.strength > $1.strength }
        var text = "Ranking by \(outcomes.count) pairwise comparisons (Bradley–Terry strength, log scale, ±95% CI; log: \(log)):\n"
        for (r, s) in scores.enumerated() {
            text += String(format: "%d. %+.2f ± %.2f · %d/%d wins · ", r + 1, s.strength, 1.96 * s.se, s.wins, s.games) + items[s.index].truncated(160, marker: "…") + "\n"
        }
        // Neighbours whose intervals overlap are not distinguishable at this number of comparisons.
        let ties = zip(scores, scores.dropFirst()).enumerated().filter { _, p in p.0.strength - 1.96 * p.0.se < p.1.strength + 1.96 * p.1.se }.map { "\($0.offset + 1)–\($0.offset + 2)" }
        if !ties.isEmpty { text += "Not separable (overlapping intervals): ranks \(ties.joined(separator: ", ")). More comparisons would be needed to order them.\n" }
        if unusable > 0 { text += "\(unusable) of \(planned) comparisons returned no usable verdict and were dropped.\n" }
        if outcomes.count >= 10 {
            let share = Double(firstWins) / Double(outcomes.count)
            if abs(share - 0.5) > 0.2 { text += String(format: "Position bias: the first-listed candidate won %.0f%% of comparisons (sides were randomised).\n", share * 100) }
        }
        return text
    }
}

// MARK: - Multimodal adaptation

/// Keeps image inputs usable with any model. When the active model cannot read images (detected
/// from models.dev / the endpoint listing / ZCode rules), images are replaced *at append time* by a
/// description from a vision-capable helper model (cached by image hash), so the stored transcript
/// stays byte-stable for caching and a text-only model still gets the content.
public final class VisionAdapter: @unchecked Sendable {
    public var helper: (LLMProvider, String)?
    private var cache: [String: String] = [:]
    private let lock = NSLock()

    public init(helper: (LLMProvider, String)? = nil) { self.helper = helper }

    public func adapt(_ blocks: [ContentBlock], modelSupportsImages: Bool) async -> [ContentBlock] {
        if modelSupportsImages { return blocks }
        var out: [ContentBlock] = []
        for b in blocks {
            switch b {
            case .image(let img):
                out.append(.text(await describe(img)))
            case .toolResult(var tr) where !tr.images.isEmpty:
                var extra: [String] = []
                for img in tr.images { extra.append(await describe(img)) }
                tr.images = []
                tr.content += "\n" + extra.joined(separator: "\n")
                out.append(.toolResult(tr))
            default:
                out.append(b)
            }
        }
        return out
    }

    func describe(_ img: ImageBlock) async -> String {
        let key = Hashing.sha256Hex(img.base64)
        if let c = lock.locked({ cache[key] }) { return c }
        guard let (p, m) = helper else {
            return "[image omitted: the current model cannot read images and no vision helper model is configured (sha256 \(key.prefix(12)))]"
        }
        let req = LLMRequest(model: m, system: "Describe scientific images precisely for a colleague who cannot see them.", tools: [],
                             messages: [Message(role: .user, blocks: [.image(img), .text("""
                             Describe this image for a researcher who cannot see it: type of figure, axes/labels/units, legend, \
                             data values you can read, notable patterns, and anything ambiguous. Do not guess unreadable values.
                             """)])], maxTokens: 1500, effort: .low, cache: CacheHints(lineageKey: "vision-helper", retention: .short))
        let text = (try? await p.complete(req).message.plainText) ?? "(vision helper failed)"
        let desc = "[image described by \(m) because the current model cannot read images (sha256 \(key.prefix(12)))]\n\(text)"
        lock.locked { cache[key] = desc }
        return desc
    }
}
