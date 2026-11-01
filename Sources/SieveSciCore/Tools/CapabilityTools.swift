import Foundation

// MARK: - Library-wide evidence search (PaperQA2 / OpenScholar style, lexical BM25)

/// Ranks passages across *all* papers in the task library for a question and returns the best ones
/// with their citation keys — the retrieval half of PaperQA2's retrieve → summarize → answer loop.
struct LibrarySearchTool: Tool {
    let name = "library_search"
    let description = """
    Search the full texts of every paper in this task's library (BM25 over paragraphs) and return the most \
    relevant passages with their [@key]. Use it to gather evidence for or against a statement across papers. \
    Before concluding, run it with stance "contradicting": it returns only passages on the same topic that \
    report null results, failed replications or opposite findings.
    """
    var inputSchema: JSON {
        Schema.object(["query": Schema.string("Question or statement"), "limit": Schema.integer("Passages, default 8"),
                       "stance": Schema.stringEnum("any (default) or contradicting", ["any", "contradicting"])], required: ["query"])
    }

    /// Wording of null results, failed replications and opposing findings, with weights (strong → weak).
    static let contradictionCues: [(String, Double)] = [
        (#"(?i)\b(fail(ed|s)? to (replicate|reproduce|confirm)|could not (be )?(replicate|reproduce|confirm)|did not replicate|not replicated|non-?replicat\w*)\b"#, 3),
        (#"(?i)\b(contrary to|contradict\w*|refut\w*|inconsistent with|in contrast to|opposite (effect|direction))\b"#, 2.5),
        (#"(?i)\b(no (significant |detectable |measurable )?(effect|association|difference|correlation|change|evidence|benefit)|not (significantly )?(associated|correlated|different|altered|affected|observed)|did not (differ|affect|change|alter|increase|decrease|improve|reduce)|null (result|finding|effect)s?)\b"#, 2),
        (#"(?i)\b(however|whereas|but not|unlike|conflicting|controversial|debated)\b"#, 0.75),
    ]

    static func contradictionWeight(_ passage: String) -> (Double, String?) {
        var w = 0.0, first: String?
        for (pattern, weight) in contradictionCues {
            if let r = passage.range(of: pattern, options: .regularExpression) {
                w += weight
                if first == nil { first = String(passage[r]) }
            }
        }
        return (w, first)
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    static func tokens(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 2 }
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let lib = ctx.services.library
        let q = Self.tokens(try input.required("query"))
        var docs: [(key: String, text: String, toks: [String])] = []
        for r in lib.records {
            guard let t = lib.text(r.key) else { continue }
            for p in t.components(separatedBy: "\n\n") where p.count > 120 { docs.append((r.key, p, Self.tokens(p))) }
        }
        guard !docs.isEmpty else { return .error("The library has no texts yet; add papers with paper_fetch.") }
        let n = Double(docs.count)
        let avg = docs.reduce(0) { $0 + Double($1.toks.count) } / n
        var df: [String: Double] = [:]
        for d in docs { for t in Set(d.toks) where q.contains(t) { df[t, default: 0] += 1 } }
        let k1 = 1.2, b = 0.75
        let scored = docs.map { d -> Double in
            var tf: [String: Double] = [:]
            for t in d.toks where df[t] != nil { tf[t, default: 0] += 1 }
            let s = q.reduce(0.0) { acc, t in
                guard let f = tf[t], let dft = df[t] else { return acc }
                let idf = log(1 + (n - dft + 0.5) / (dft + 0.5))
                return acc + idf * f * (k1 + 1) / (f + k1 * (1 - b + b * Double(d.toks.count) / avg))
            }
            return s
        }
        let contradicting = input.str("stance") == "contradicting"
        if contradicting {
            // Same topic (several query terms in common) and opposing wording; ranked by both.
            let need = max(1, min(3, (Set(q).count + 1) / 2))
            var hits: [(Int, Double, String)] = []
            for (i, d) in docs.enumerated() where scored[i] > 0 && Set(d.toks).intersection(q).count >= need {
                let (w, cue) = Self.contradictionWeight(d.text)
                if w >= 2, let cue { hits.append((i, scored[i] * (1 + w / 2), cue)) }
            }
            hits.sort { $0.1 > $1.1 }
            ctx.services.emit(.literature(agentId: ctx.sessionId, action: .read, key: "library", title: "contradiction search", detail: input.str("query") ?? ""))
            if hits.isEmpty {
                return ToolOutput("No passage in the library contradicts this (no null-result, failed-replication or opposing wording on the same topic). That is weak evidence of consensus: the library may simply lack such papers — also check citing papers with `paper_graph` and search for \"failed replication\" / \"no association\".")
            }
            return ToolOutput("Passages that may contradict the statement (read them in full before weighing them):\n\n" + hits.prefix(input.int("limit") ?? 8).map {
                "[@\(docs[$0.0].key)] (score \(String(format: "%.1f", $0.1)); cue: “\($0.2)”)\n> \(docs[$0.0].text.truncated(1000, marker: "…"))"
            }.joined(separator: "\n\n"))
        }
        let order = scored.enumerated().filter { $0.element > 0 }.sorted { $0.element > $1.element }.prefix(input.int("limit") ?? 8)
        if order.isEmpty { return ToolOutput("No passage matches; the library may not cover this question — search the literature.") }
        ctx.services.emit(.literature(agentId: ctx.sessionId, action: .read, key: "library", title: "library-wide search", detail: input.str("query") ?? ""))
        return ToolOutput(order.map { "[@\(docs[$0.offset].key)] (score \(String(format: "%.1f", $0.element)))\n> \(docs[$0.offset].text.truncated(1000, marker: "…"))" }.joined(separator: "\n\n"))
    }
}

// MARK: - Chemistry (ChemCrow-derived)

/// The controlled-substance screen behind `chem_lookup`. The list (Australia Group / CWC
/// chemical-weapons precursors, CAS + SMILES) is ChemCrow's `chem_wep_smi.csv` (MIT); each entry's
/// InChIKey is precomputed by `scripts/gen-controlled-inchikeys.py`. Matching is by structure, so a
/// re-written SMILES (atom order, explicit H, Kekulé vs aromatic) or a stereoisomer is still caught:
/// exact CAS / SMILES first (offline), then the full InChIKey, then its first block (connectivity).
public struct ChemScreen: Sendable {
    public struct Entry: Sendable, Equatable {
        public var cas: String, source: String, smiles: String, inchikey: String?
        public init(cas: String, source: String, smiles: String, inchikey: String?) {
            self.cas = cas; self.source = source; self.smiles = smiles; self.inchikey = inchikey
        }
    }

    public enum Basis: String, Sendable { case cas, smiles, inchikey, connectivity }

    public struct Hit: Sendable, Equatable {
        public var cas: String, source: String, basis: Basis
    }

    public let entries: [Entry]
    private let byCAS: [String: Entry]
    private let bySMILES: [String: Entry]
    private let byKey: [String: Entry]
    private let bySkeleton: [String: Entry]

    public init(entries: [Entry]) {
        self.entries = entries
        func index(_ k: (Entry) -> String?) -> [String: Entry] {
            var d: [String: Entry] = [:]
            for e in entries { if let key = k(e), !key.isEmpty, d[key] == nil { d[key] = e } }
            return d
        }
        byCAS = index { $0.cas }
        bySMILES = index { $0.smiles }
        byKey = index { $0.inchikey?.uppercased() }
        bySkeleton = index { $0.inchikey.flatMap(Self.skeleton) }
    }

    /// The bundled list: the InChIKey catalog, or the CSV alone (exact matching only) if it is missing.
    public static let bundled: ChemScreen = {
        let dir = "Resources/catalog"
        if let u = SieveSciResources.bundle.url(forResource: "chemcrow-chem-weapons-inchikeys", withExtension: "json", subdirectory: dir),
           let d = try? Data(contentsOf: u), let j = try? JSONDecoder().decode(JSON.self, from: d),
           let rows = j["entries"]?.arrayValue, !rows.isEmpty {
            return ChemScreen(entries: rows.compactMap { r in
                guard let cas = r.str("cas"), let smiles = r.str("smiles") else { return nil }
                return Entry(cas: cas, source: r.str("source") ?? "", smiles: smiles, inchikey: r.str("inchikey"))
            })
        }
        guard let u = SieveSciResources.bundle.url(forResource: "chemcrow-chem-weapons", withExtension: "csv", subdirectory: dir),
              let t = try? String(contentsOf: u, encoding: .utf8) else { return ChemScreen(entries: []) }
        return ChemScreen(entries: t.split(separator: "\n").dropFirst().compactMap { line in
            let f = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 3 else { return nil }
            return Entry(cas: f[0].trimmingCharacters(in: CharacterSet(charactersIn: "() ")), source: f[1], smiles: f[2], inchikey: nil)
        })
    }()

    static let inchikeyPattern = #"^[A-Z]{14}-[A-Z]{10}-[A-Z]$"#

    public static func isInChIKey(_ s: String) -> Bool { s.range(of: inchikeyPattern, options: .regularExpression) != nil }

    /// First InChIKey block: the molecular skeleton, independent of stereo, isotopes and protonation.
    static func skeleton(_ key: String) -> String? {
        let k = key.uppercased()
        guard isInChIKey(k) else { return nil }
        return String(k.prefix(14))
    }

    public func match(cas: [String] = [], smiles: [String] = [], inchikeys: [String] = []) -> Hit? {
        for c in cas { if let e = byCAS[c.trimmingCharacters(in: .whitespaces)] { return Hit(cas: e.cas, source: e.source, basis: .cas) } }
        for s in smiles { if let e = bySMILES[s.trimmingCharacters(in: .whitespaces)] { return Hit(cas: e.cas, source: e.source, basis: .smiles) } }
        let keys = inchikeys.map { $0.trimmingCharacters(in: .whitespaces).uppercased() }
        for k in keys { if let e = byKey[k] { return Hit(cas: e.cas, source: e.source, basis: .inchikey) } }
        for k in keys { if let sk = Self.skeleton(k), let e = bySkeleton[sk] { return Hit(cas: e.cas, source: e.source, basis: .connectivity) } }
        return nil
    }

    /// InChIKeys of a SMILES computed locally with RDKit — of the whole input and of its largest
    /// fragment (salts and solvates stripped). nil when RDKit is unavailable or the SMILES does not parse.
    public static func localInChIKeys(_ smiles: String) async -> [String]? {
        let script = """
        import sys
        try:
            from rdkit import Chem, RDLogger
        except Exception:
            sys.exit(3)
        RDLogger.DisableLog("rdApp.*")
        m = Chem.MolFromSmiles(sys.argv[1])
        if m is None:
            sys.exit(4)
        keys = [Chem.MolToInchiKey(m)]
        frags = Chem.GetMolFrags(m, asMols=True)
        if len(frags) > 1:
            keys.append(Chem.MolToInchiKey(max(frags, key=lambda f: f.GetNumHeavyAtoms())))
        print("\\n".join(k for k in keys if k))
        """
        guard let r = try? await ProcessRunner.run("python3", ["-c", script, smiles], timeout: 30), r.exitCode == 0 else { return nil }
        let keys = r.stdout.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }.filter(isInChIKey)
        return keys.isEmpty ? nil : keys
    }
}

/// PubChem lookup with a mandatory safety screen (`ChemScreen`).
struct ChemLookupTool: Tool {
    let name = "chem_lookup"
    let description = """
    Look up a chemical by name, CAS number, SMILES or InChIKey in PubChem: identifiers, formula, molecular \
    weight, canonical SMILES and GHS hazard statements, and screen it against controlled chemical-weapons \
    precursor lists. Run it before discussing handling, synthesis or procurement of any compound.
    """
    var inputSchema: JSON { Schema.object(["query": Schema.string("Name, CAS number, SMILES or InChIKey")], required: ["query"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    var screen: ChemScreen = .bundled
    /// Local SMILES → InChIKeys, used when PubChem cannot resolve a SMILES. Replaceable in tests.
    var localKeys: @Sendable (String) async -> [String]? = { await ChemScreen.localInChIKeys($0) }

    static let pug = "https://pubchem.ncbi.nlm.nih.gov/rest/pug"

    static func isSMILES(_ q: String) -> Bool {
        q.range(of: #"^[A-Za-z0-9@+\-\[\]\(\)=#$/\\%.]+$"#, options: .regularExpression) != nil
            && q.rangeOfCharacter(from: CharacterSet(charactersIn: "=()[]#")) != nil
    }

    static func controlledNote(_ hit: ChemScreen.Hit) -> String {
        "⚠ CONTROLLED SUBSTANCE: on the \(hit.source) list (CAS \(hit.cas)). Do not provide synthesis, production, weaponization or acquisition guidance; discuss only in safety, detection or regulatory terms."
    }

    private func flag(_ hit: ChemScreen.Hit, query: String, _ ctx: ToolContext) {
        ctx.services.log("chem_safety_flag", actor: ctx.role.rawValue,
                         ["query": .string(query), "cas": .string(hit.cas), "list": .string(hit.source), "basis": .string(hit.basis.rawValue)])
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let q = try input.required("query").trimmingCharacters(in: .whitespaces)
        let lib = ctx.services.library
        let isKey = ChemScreen.isInChIKey(q.uppercased())
        let isSmiles = !isKey && Self.isSMILES(q)
        // Offline first: an exact CAS / SMILES / InChIKey hit needs no network.
        if let hit = screen.match(cas: [q], smiles: [q], inchikeys: isKey ? [q] : []) {
            flag(hit, query: q, ctx)
            return .error("⚠ CONTROLLED: \(q) is on the \(hit.source) list (CAS \(hit.cas)). Do not provide synthesis, production or acquisition guidance.")
        }
        let ns = isKey ? "inchikey" : isSmiles ? "smiles" : "name"
        let enc = (isKey ? q.uppercased() : q).addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? q
        guard let props = try? await lib.get("\(Self.pug)/compound/\(ns)/\(enc)/property/MolecularFormula,MolecularWeight,CanonicalSMILES,IsomericSMILES,IUPACName,InChIKey/JSON"),
              let p = props["PropertyTable"]?["Properties"]?[0], let cid = p.int("CID") else {
            // PubChem could not resolve it: canonicalise a SMILES locally before giving up.
            if isSmiles {
                guard let keys = await localKeys(q) else {
                    return .error("PubChem has no compound for “\(q)”, and the structure could not be checked locally (RDKit is not installed or the SMILES does not parse), so it was NOT screened by structure against the controlled-substance list. Treat it as unscreened.")
                }
                if let hit = screen.match(inchikeys: keys) {
                    flag(hit, query: q, ctx)
                    return .error("⚠ CONTROLLED: \(q) is on the \(hit.source) list (CAS \(hit.cas)). Do not provide synthesis, production or acquisition guidance.")
                }
                return .error("PubChem has no compound for “\(q)”. Structure screened locally (InChIKey \(keys[0])): not on the controlled-substance list.")
            }
            return .error("PubChem has no compound for “\(q)”.")
        }
        var cas: [String] = []
        if let syn = try? await lib.get("\(Self.pug)/compound/cid/\(cid)/synonyms/JSON") {
            cas = (syn["InformationList"]?["Information"]?[0]?["Synonym"]?.arrayValue ?? []).compactMap(\.stringValue)
                .filter { $0.range(of: #"^\d{2,7}-\d{2}-\d$"#, options: .regularExpression) != nil }
        }
        // Salts, hydrates and mixtures get their own CID and InChIKey; screen the parent compound too.
        var keys = [p.str("InChIKey")].compactMap { $0 }
        if let par = try? await lib.get("\(Self.pug)/compound/cid/\(cid)/cids/JSON?cids_type=parent") {
            let parents = (par["IdentifierList"]?["CID"]?.arrayValue ?? []).compactMap { $0.numberValue.map { Int($0) } }.filter { $0 != cid }
            if !parents.isEmpty, let pp = try? await lib.get("\(Self.pug)/compound/cid/\(parents.map(String.init).joined(separator: ","))/property/InChIKey/JSON") {
                keys += (pp["PropertyTable"]?["Properties"]?.arrayValue ?? []).compactMap { $0.str("InChIKey") }
            }
        }
        var ghs: [String] = []
        if let view = try? await lib.get("https://pubchem.ncbi.nlm.nih.gov/rest/pug_view/data/compound/\(cid)/JSON?heading=GHS+Classification") {
            let text = view.canonical
            ghs = Array(Set(Grounding.matches(#"H\d{3}[A-Za-z]*: [^"\\]{5,120}"#, in: text))).sorted().prefix(12).map { $0 }
        }
        let smiles = [p.str("CanonicalSMILES"), p.str("IsomericSMILES"), p.str("SMILES"), p.str("ConnectivitySMILES")].compactMap { $0 }
        var out = """
        PubChem CID \(cid) · \(p.str("IUPACName") ?? q)
        Formula \(p.str("MolecularFormula") ?? "?") · MW \(p["MolecularWeight"]?.stringValue ?? p["MolecularWeight"]?.numberValue.map { String($0) } ?? "?")
        SMILES \(smiles.first ?? "?") · InChIKey \(p.str("InChIKey") ?? "?")
        CAS \(cas.prefix(3).joined(separator: ", "))
        GHS hazards: \(ghs.isEmpty ? "none listed in PubChem" : "\n  " + ghs.joined(separator: "\n  "))
        """
        if let hit = screen.match(cas: cas, smiles: smiles, inchikeys: keys) {
            out = Self.controlledNote(hit) + "\n\n" + out
            flag(hit, query: q, ctx)
        }
        return ToolOutput(out)
    }
}

// MARK: - Biomni tools (via the Python kernel)

/// Finds relevant Biomni functions (224 tools across genomics, cell biology, pharmacology,
/// immunology …) and data-lake datasets. Biomni's own tools run inside the persistent Python kernel
/// (`from biomni.tool.genetics import liftover_coordinates`), exactly as Biomni's A1 agent uses
/// them — so 224 tools add nothing to the cached tool list. Index generated from Biomni (Apache-2.0).
struct BioToolSearchTool: Tool {
    let name = "bio_tool_search"
    let description = """
    Search Biomni's biomedical tool library (224 functions: CRISPR design, liftover, GWAS, scRNA-seq \
    annotation, docking, pathway and drug databases…) and its data lake. Returns the module, function name, \
    parameters and description to call it from the python tool (requires `pip install biomni`; data lake \
    path from BIOMNI_DATA_PATH).
    """
    var inputSchema: JSON { Schema.object(["query": Schema.string("What you need to do"), "limit": Schema.integer("Default 8")], required: ["query"]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    static let index: JSON? = {
        guard let u = SieveSciResources.bundle.url(forResource: "biomni-tools", withExtension: "json", subdirectory: "Resources/catalog"),
              let d = try? Data(contentsOf: u) else { return nil }
        return try? JSONCodec.parse(d)
    }()

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let idx = Self.index else { return .error("Biomni index missing.") }
        let q = LibrarySearchTool.tokens(try input.required("query"))
        func score(_ s: String) -> Int { let l = s.lowercased(); return q.reduce(0) { $0 + (l.contains($1) ? 1 : 0) } }
        var scoredTools: [(Int, JSON)] = []
        for t in idx["tools"]?.arrayValue ?? [] {
            let name = (t.str("name") ?? "").replacingOccurrences(of: "_", with: " ")
            let sc = score(name + " " + (t.str("description") ?? ""))
            if sc > 0 { scoredTools.append((sc, t)) }
        }
        let tools = scoredTools.sorted { $0.0 > $1.0 }.prefix(input.int("limit") ?? 8)
        var scoredData: [(Int, String, String)] = []
        for (k, v) in idx["data_lake"]?.objectValue ?? [:] {
            let desc = v.stringValue ?? ""
            let sc = score(k + " " + desc)
            if sc > 0 { scoredData.append((sc, k, desc)) }
        }
        let data = scoredData.sorted { $0.0 > $1.0 }.prefix(5)
        let installed = (try? await ProcessRunner.run("python3", ["-c", "import importlib.util,sys;sys.exit(0 if importlib.util.find_spec('biomni') else 1)"], timeout: 20))?.exitCode == 0
        var out = installed ? "biomni is installed.\n" : "biomni is NOT installed in this Python (pip install biomni) — install it or use other methods.\n"
        for (_, t) in tools {
            let req = (t["required"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            let opt = (t["optional"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            let sig = req + (opt.isEmpty ? "" : ", [optional: \(opt)]")
            let desc = t.str("description")?.truncated(300, marker: "…") ?? ""
            out += "• \(t.str("module") ?? "").\(t.str("name") ?? "")(\(sig))\n  \(desc)\n"
        }
        if !data.isEmpty {
            out += "\n\nData lake (under $BIOMNI_DATA_PATH/data_lake):\n" + data.map { "• \($0.1): \($0.2.truncated(160, marker: "…"))" }.joined(separator: "\n")
        }
        return ToolOutput(tools.isEmpty && data.isEmpty ? "No Biomni tool matches; use standard libraries instead." : out)
    }
}

// MARK: - Repo map (Aider style)

/// A compact map of the workspace's code: files with their top-level functions and classes, so the
/// agent can find where things are defined without reading every file.
struct RepoMapTool: Tool {
    let name = "repo_map"
    let description = "Map of the workspace's code: each source file with its top-level functions/classes (Python, R, Julia, Swift, shell, JS/TS, Rust, Go). Use it to orient before reading files."
    var inputSchema: JSON { Schema.object(["path": Schema.string("Subdirectory (default workspace)")]) }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    static let patterns: [String: String] = [
        "py": #"^(?:async\s+)?def\s+(\w+)|^class\s+(\w+)"#, "r": #"^([\w.]+)\s*(?:<-|=)\s*function"#, "R": #"^([\w.]+)\s*(?:<-|=)\s*function"#,
        "jl": #"^function\s+(\w+)|^(?:mutable\s+)?struct\s+(\w+)"#, "swift": #"^\s*(?:public\s+|private\s+|internal\s+)?(?:final\s+)?(?:func|class|struct|enum|protocol)\s+(\w+)"#,
        "sh": #"^(\w+)\s*\(\)\s*\{"#, "js": #"^(?:export\s+)?(?:async\s+)?function\s+(\w+)|^(?:export\s+)?class\s+(\w+)"#,
        "ts": #"^(?:export\s+)?(?:async\s+)?function\s+(\w+)|^(?:export\s+)?(?:class|interface)\s+(\w+)"#,
        "rs": #"^\s*(?:pub\s+)?(?:fn|struct|enum|trait)\s+(\w+)"#, "go": #"^func\s+(?:\([^)]*\)\s*)?(\w+)|^type\s+(\w+)"#,
    ]

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let root = try ctx.resolve(input.str("path") ?? ".")
        var out: [String] = []
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]) else { return .error("no such directory") }
        for case let u as URL in en {
            if ["node_modules", ".build", "__pycache__", ".venv", "venv", "dist", "build"].contains(u.lastPathComponent) { en.skipDescendants(); continue }
            guard let pat = Self.patterns[u.pathExtension], (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 1_000_000,
                  (try? ctx.checkReadable(u)) != nil, let t = try? String(contentsOf: u, encoding: .utf8),
                  let re = try? NSRegularExpression(pattern: pat, options: [.anchorsMatchLines]) else { continue }
            let names = re.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { m -> String? in
                for g in 1..<m.numberOfRanges { if let r = Range(m.range(at: g), in: t) { return String(t[r]) } }
                return nil
            }
            out.append(String(u.path.dropFirst(root.path.count + 1)) + (names.isEmpty ? "" : ": " + names.prefix(40).joined(separator: ", ")))
            if out.count >= 400 { out.append("… (truncated)"); break }
        }
        return ToolOutput(out.isEmpty ? "No source files." : out.sorted().joined(separator: "\n"))
    }
}

// MARK: - Edit syntax check (SWE-agent / Aider "lint on edit")

/// Checks that an edited source file still parses. An edit that breaks a file that parsed before is
/// rolled back (SWE-agent's edit-linting rule), so the agent never leaves a broken file behind.
enum SyntaxCheck {
    /// nil = fine or unknown language; otherwise the error message.
    static func check(path: String) async -> String? {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "py":
            let r = try? await ProcessRunner.run("python3", ["-c", "import ast,sys;ast.parse(open(sys.argv[1],encoding='utf-8').read(),sys.argv[1])", path], timeout: 30)
            return r.flatMap { $0.exitCode == 0 ? nil : $0.stderr.truncated(800) }
        case "r":
            guard ProcessRunner.which("Rscript") != nil else { return nil }
            let r = try? await ProcessRunner.run("Rscript", ["-e", "invisible(parse(commandArgs(TRUE)[1]))", path], timeout: 30)
            return r.flatMap { $0.exitCode == 0 ? nil : $0.stderr.truncated(800) }
        case "json", "ipynb":
            guard let d = FileManager.default.contents(atPath: path) else { return nil }
            return (try? JSONSerialization.jsonObject(with: d)) == nil ? "invalid JSON" : nil
        default:
            return nil
        }
    }
}
