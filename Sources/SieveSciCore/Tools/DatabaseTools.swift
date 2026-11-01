import Foundation

// MARK: - Native biology / chemistry / clinical databases

/// One tool over the public REST APIs research agents use most: UniProt, NCBI E-utilities (Gene,
/// PubMed, GEO, SRA, Nucleotide, Protein), RCSB PDB, AlphaFold DB, Ensembl, ChEMBL, Reactome and
/// ClinicalTrials.gov v2. Every answer is a receipt, so numbers quoted from it are grounded.
/// ChEMBL molecules go through the same controlled-substance screen as `chem_lookup`.
struct BioDatabaseTool: Tool {
    let name = "bio_db"
    let description = """
    Query public biology, chemistry and clinical databases directly. database: uniprot (proteins: function, \
    gene, organism), ncbi (E-utilities; set ncbi_db to gene, pubmed, gds (GEO datasets), sra, nuccore or \
    protein), pdb (RCSB structures), alphafold (predicted structure for a UniProt accession), ensembl \
    (genes by symbol or stable id; species default homo_sapiens), chembl (molecules or targets, with \
    bioactivity counts), reactome (pathways), clinicaltrials (ClinicalTrials.gov studies: status, phase, \
    conditions, interventions, enrollment). Give `query` to search or `id` to fetch one record.
    """
    static let databases = ["uniprot", "ncbi", "pdb", "alphafold", "ensembl", "chembl", "reactome", "clinicaltrials"]
    var inputSchema: JSON {
        Schema.object([
            "database": Schema.stringEnum("Which database", Self.databases),
            "query": Schema.string("Search text (gene, protein, disease, compound, keywords)"),
            "id": Schema.string("Fetch one record: UniProt accession, NCBI id, PDB id, Ensembl id, ChEMBL id, Reactome stable id, NCT number"),
            "ncbi_db": Schema.stringEnum("ncbi only", ["gene", "pubmed", "gds", "sra", "nuccore", "protein"]),
            "species": Schema.string("ensembl only, e.g. homo_sapiens, mus_musculus"),
            "kind": Schema.stringEnum("chembl only: molecule (default) or target", ["molecule", "target"]),
            "limit": Schema.integer("Search results, default 8, max 25"),
        ], required: ["database"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    var screen: ChemScreen = .bundled

    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let db = try input.required("database")
        let query = input.str("query")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        let id = input.str("id")?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        guard query != nil || id != nil else { return .error("Give `query` (search) or `id` (one record).") }
        let limit = max(1, min(input.int("limit") ?? 8, 25))
        let lib = ctx.services.library
        // Public APIs rate-limit (NCBI: 3 requests/s without a key) and have transient outages.
        let get: @Sendable (String) async throws -> JSON = { url in
            var attempt = 0
            while true {
                do { return try await lib.get(url) } catch ProviderError.http(let status, let body) where status == 429 || status >= 500 {
                    attempt += 1
                    if attempt > 2 { throw ProviderError.http(status: status, body: body) }
                    try await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000)
                }
            }
        }
        do {
            let text: String
            switch db {
            case "uniprot": text = try await uniprot(query: query, id: id, limit: limit, get)
            case "ncbi": text = try await ncbi(db: input.str("ncbi_db") ?? "gene", query: query, id: id, limit: limit,
                                               key: ctx.services.secrets.secret(for: "NCBI_API_KEY"), get)
            case "pdb": text = try await pdb(query: query, id: id, limit: limit, get)
            case "alphafold":
                guard let acc = id ?? query else { return .error("alphafold needs a UniProt accession") }
                text = try await alphafold(acc, get)
            case "ensembl": text = try await ensembl(query: query, id: id, species: input.str("species") ?? "homo_sapiens", get)
            case "chembl":
                let (t, hits) = try await chembl(kind: input.str("kind") ?? "molecule", query: query, id: id, limit: limit, get)
                for h in hits {
                    ctx.services.log("chem_safety_flag", actor: ctx.role.rawValue,
                                     ["query": .string(query ?? id ?? ""), "cas": .string(h.cas), "list": .string(h.source), "basis": .string(h.basis.rawValue)])
                }
                text = t
            case "reactome": text = try await reactome(query: query, id: id, limit: limit, get)
            case "clinicaltrials": text = try await clinicalTrials(query: query, id: id, limit: limit, get)
            default: return .error("Unknown database \(db). Use one of: \(Self.databases.joined(separator: ", ")).")
            }
            return text.isEmpty ? .error("No \(db) results for “\(query ?? id ?? "")”.") : ToolOutput(text)
        } catch ProviderError.http(let status, _) where status == 404 || status == 400 {
            return .error("No \(db) record for “\(query ?? id ?? "")” (HTTP \(status)).")
        } catch ProviderError.http(let status, _) {
            return .error("\(db) is unavailable right now (HTTP \(status) after retries). Try again later or another database; do not guess the record.")
        }
    }

    // MARK: UniProt

    func uniprot(query: String?, id: String?, limit: Int, _ get: (String) async throws -> JSON) async throws -> String {
        let base = "https://rest.uniprot.org/uniprotkb"
        let entries: [JSON]
        if let id {
            entries = [try await get("\(base)/\(Self.q(id)).json")]
        } else {
            let fields = "accession,id,protein_name,gene_names,organism_name,length,cc_function,reviewed"
            entries = try await get("\(base)/search?query=\(Self.q(query!))&fields=\(fields)&format=json&size=\(limit)")["results"]?.arrayValue ?? []
        }
        return entries.map { e in
            let acc = e.str("primaryAccession") ?? "?"
            let name = e["proteinDescription"]?["recommendedName"]?["fullName"]?["value"]?.stringValue
                ?? e["proteinDescription"]?["submissionNames"]?[0]?["fullName"]?["value"]?.stringValue ?? "?"
            let genes = (e["genes"]?.arrayValue ?? []).compactMap { $0["geneName"]?["value"]?.stringValue }.joined(separator: ", ")
            let org = e["organism"]?["scientificName"]?.stringValue ?? "?"
            let len = e["sequence"]?["length"]?.numberValue.map { String(Int($0)) } ?? "?"
            let reviewed = (e.str("entryType") ?? "").contains("reviewed") && !(e.str("entryType") ?? "").contains("unreviewed")
            let function = (e["comments"]?.arrayValue ?? []).first { $0.str("commentType") == "FUNCTION" }?["texts"]?[0]?["value"]?.stringValue
            return "UniProt \(acc) (\(e.str("uniProtkbId") ?? "")\(reviewed ? ", Swiss-Prot" : "")) · \(name)\n  gene \(genes.isEmpty ? "—" : genes) · \(org) · \(len) aa"
                + (function.map { "\n  function: " + $0.truncated(500, marker: "…") } ?? "")
                + "\n  https://www.uniprot.org/uniprotkb/\(acc)"
        }.joined(separator: "\n")
    }

    // MARK: NCBI E-utilities

    func ncbi(db: String, query: String?, id: String?, limit: Int, key: String?, _ get: (String) async throws -> JSON) async throws -> String {
        let base = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"
        let keyParam = key.map { "&api_key=\(Self.q($0))" } ?? ""
        var ids: [String]
        var total: String?
        if let id {
            ids = id.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        } else {
            let s = try await get("\(base)/esearch.fcgi?db=\(db)&term=\(Self.q(query!))&retmode=json&retmax=\(limit)\(keyParam)")
            ids = (s["esearchresult"]?["idlist"]?.arrayValue ?? []).compactMap(\.stringValue)
            total = s["esearchresult"]?["count"]?.stringValue
        }
        guard !ids.isEmpty else { return "" }
        let sum = try await get("\(base)/esummary.fcgi?db=\(db)&id=\(ids.joined(separator: ","))&retmode=json\(keyParam)")
        let result = sum["result"]
        let lines = ids.compactMap { uid -> String? in
            guard let r = result?[uid] else { return nil }
            switch db {
            case "gene":
                let org = r["organism"]?["scientificname"]?.stringValue ?? ""
                return "Gene \(uid) · \(r.str("name") ?? "?") — \(r.str("description") ?? "") (\(org))\n  \(r.str("summary")?.truncated(400, marker: "…") ?? "")\n  https://www.ncbi.nlm.nih.gov/gene/\(uid)"
            case "pubmed":
                let authors = (r["authors"]?.arrayValue ?? []).prefix(3).compactMap { $0.str("name") }.joined(separator: ", ")
                let doi = (r["articleids"]?.arrayValue ?? []).first { $0.str("idtype") == "doi" }?.str("value")
                return "PMID \(uid) · \(r.str("title") ?? "?") — \(authors) (\(r.str("pubdate") ?? ""), \(r.str("source") ?? ""))\(doi.map { "\n  doi:\($0)" } ?? "")"
            case "gds":
                return "GEO \(r.str("accession") ?? uid) · \(r.str("title") ?? "?") (\(r.str("taxon") ?? ""), \(r.str("gdstype") ?? ""), \(r["n_samples"]?.numberValue.map { String(Int($0)) } ?? "?") samples)\n  \(r.str("summary")?.truncated(300, marker: "…") ?? "")"
            case "sra":
                let exp = r.str("expxml") ?? ""
                let title = Grounding.matches(#"<Title>(.*?)</Title>"#, in: exp, group: 1).first ?? "?"
                let acc = Grounding.matches(#"<Experiment acc="([^"]+)""#, in: exp, group: 1).first ?? uid
                return "SRA \(acc) · \(title)"
            default:
                return "\(db) \(uid) · \(r.str("title") ?? r.str("caption") ?? "?")\(r["slen"]?.numberValue.map { " · \(Int($0)) bp/aa" } ?? "")"
            }
        }
        return (total.map { "\($0) matches; showing \(lines.count)\n" } ?? "") + lines.joined(separator: "\n")
    }

    // MARK: RCSB PDB and AlphaFold

    func pdb(query: String?, id: String?, limit: Int, _ get: (String) async throws -> JSON) async throws -> String {
        var ids: [String]
        if let id { ids = [id.uppercased()] } else {
            let req: JSON = ["query": ["type": "terminal", "service": "full_text", "parameters": ["value": .string(query!)]],
                             "return_type": "entry", "request_options": ["paginate": ["start": 0, "rows": .int(limit)]]]
            let s = try await get("https://search.rcsb.org/rcsbsearch/v2/query?json=\(Self.q(req.canonical))")
            ids = (s["result_set"]?.arrayValue ?? []).compactMap { $0.str("identifier") }
        }
        var lines: [String] = []
        for pid in ids.prefix(limit) {
            guard let e = try? await get("https://data.rcsb.org/rest/v1/core/entry/\(Self.q(pid))") else { lines.append("PDB \(pid)"); continue }
            let method = e["exptl"]?[0]?.str("method") ?? "?"
            let res = e["rcsb_entry_info"]?["resolution_combined"]?[0]?.numberValue.map { String(format: "%.2f Å", $0) } ?? "—"
            let date = e["rcsb_accession_info"]?.str("initial_release_date")?.prefix(10) ?? "?"
            lines.append("PDB \(pid) · \(e["struct"]?.str("title") ?? "?")\n  \(method) · resolution \(res) · released \(date) · https://www.rcsb.org/structure/\(pid)")
        }
        return lines.joined(separator: "\n")
    }

    func alphafold(_ acc: String, _ get: (String) async throws -> JSON) async throws -> String {
        let j = try await get("https://alphafold.ebi.ac.uk/api/prediction/\(Self.q(acc))")
        // Isoform models follow the canonical one; show the first few.
        return (j.arrayValue ?? [j]).prefix(3).map { m in
            "AlphaFold \(m.str("entryId") ?? "?") · \(m.str("uniprotDescription") ?? "") (\(m.str("organismScientificName") ?? ""))\n"
                + "  model v\(m["latestVersion"]?.numberValue.map { String(Int($0)) } ?? "?") · mean pLDDT \(m["globalMetricValue"]?.numberValue.map { String(format: "%.1f", $0) } ?? "?")\n"
                + "  \(m.str("pdbUrl") ?? "")"
        }.joined(separator: "\n")
    }

    // MARK: Ensembl

    func ensembl(query: String?, id: String?, species: String, _ get: (String) async throws -> JSON) async throws -> String {
        let base = "https://rest.ensembl.org"
        let j = try await get(id.map { "\(base)/lookup/id/\(Self.q($0))?content-type=application/json" }
            ?? "\(base)/lookup/symbol/\(Self.q(species))/\(Self.q(query!))?content-type=application/json")
        guard let gid = j.str("id") else { return "" }
        let loc = "\(j.str("seq_region_name") ?? "?"):\(j.int("start") ?? 0)-\(j.int("end") ?? 0) (\((j.int("strand") ?? 1) > 0 ? "+" : "−"))"
        return "Ensembl \(gid) · \(j.str("display_name") ?? "?") — \(j.str("description") ?? "")\n  \(j.str("biotype") ?? "") · \(j.str("species") ?? species) · \(j.str("assembly_name") ?? "") \(loc)\n  https://www.ensembl.org/id/\(gid)"
    }

    // MARK: ChEMBL

    func chembl(kind: String, query: String?, id: String?, limit: Int, _ get: (String) async throws -> JSON) async throws -> (String, [ChemScreen.Hit]) {
        let base = "https://www.ebi.ac.uk/chembl/api/data"
        if kind == "target" {
            let ts: [JSON]
            if let id { ts = [try await get("\(base)/target/\(Self.q(id)).json")] }
            else {
                // Search ranks complexes and PPIs alongside proteins; single proteins first, then by score.
                let found = try await get("\(base)/target/search.json?q=\(Self.q(query!))&limit=\(min(limit * 3, 50))")["targets"]?.arrayValue ?? []
                ts = Array((found.filter { $0.str("target_type") == "SINGLE PROTEIN" } + found.filter { $0.str("target_type") != "SINGLE PROTEIN" }).prefix(limit))
            }
            var lines: [String] = []
            for t in ts {
                let tid = t.str("target_chembl_id") ?? "?"
                let acts = (try? await get("\(base)/activity.json?target_chembl_id=\(tid)&limit=1"))?["page_meta"]?["total_count"]?.numberValue.map { String(Int($0)) } ?? "?"
                lines.append("ChEMBL \(tid) · \(t.str("pref_name") ?? "?") (\(t.str("target_type") ?? ""), \(t.str("organism") ?? "")) · \(acts) bioactivities")
            }
            return (lines.joined(separator: "\n"), [])
        }
        let ms: [JSON]
        if let id { ms = [try await get("\(base)/molecule/\(Self.q(id)).json")] }
        else { ms = try await get("\(base)/molecule/search.json?q=\(Self.q(query!))&limit=\(limit)")["molecules"]?.arrayValue ?? [] }
        var lines: [String] = [], hits: [ChemScreen.Hit] = []
        for m in ms {
            let s = m["molecule_structures"]
            let smiles = s?.str("canonical_smiles")
            let key = s?.str("standard_inchi_key")
            let p = m["molecule_properties"]
            var line = "ChEMBL \(m.str("molecule_chembl_id") ?? "?") · \(m.str("pref_name") ?? "unnamed") · max phase \(m["max_phase"]?.stringValue ?? m["max_phase"]?.numberValue.map { String($0) } ?? "?")"
                + "\n  \(p?.str("full_molformula") ?? "?") · MW \(p?.str("full_mwt") ?? "?") · InChIKey \(key ?? "?")"
            if let hit = screen.match(smiles: [smiles].compactMap { $0 }, inchikeys: [key].compactMap { $0 }) {
                line = ChemLookupTool.controlledNote(hit) + "\n" + line
                hits.append(hit)
            }
            lines.append(line)
        }
        return (lines.joined(separator: "\n"), hits)
    }

    // MARK: Reactome

    func reactome(query: String?, id: String?, limit: Int, _ get: (String) async throws -> JSON) async throws -> String {
        let base = "https://reactome.org/ContentService"
        if let id {
            let p = try await get("\(base)/data/query/\(Self.q(id))")
            return "Reactome \(p.str("stId") ?? id) · \(p.str("displayName") ?? "?") (\(p.str("speciesName") ?? ""))\n  https://reactome.org/content/detail/\(p.str("stId") ?? id)"
        }
        let q = query!
        // A UniProt accession maps straight to its pathways through the data service.
        if q.range(of: #"^([OPQ][0-9][A-Z0-9]{3}[0-9]|[A-NR-Z][0-9]([A-Z][A-Z0-9]{2}[0-9]){1,2})$"#, options: .regularExpression) != nil {
            let ps = try await get("\(base)/data/mapping/UniProt/\(q)/pathways?species=9606").arrayValue ?? []
            return ps.prefix(limit).map { "Reactome \($0.str("stId") ?? "?") · \($0.str("displayName") ?? "?") (\($0.str("speciesName") ?? ""))" }.joined(separator: "\n")
        }
        let j: JSON
        do { j = try await get("\(base)/search/query?query=\(Self.q(q))&types=Pathway&cluster=true&rows=\(limit)") } catch ProviderError.http(let status, _) where status >= 500 {
            return "Reactome text search is unavailable (HTTP \(status)). Search by UniProt accession instead (query: P04637) or fetch a pathway by its stable id (id: R-HSA-109581)."
        }
        let entries = (j["results"]?.arrayValue ?? []).flatMap { $0["entries"]?.arrayValue ?? [] }.prefix(limit)
        return entries.map { e in
            let name = (e.str("name") ?? "?").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            let species = (e["species"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
            return "Reactome \(e.str("stId") ?? "?") · \(name) (\(species))"
        }.joined(separator: "\n")
    }

    // MARK: ClinicalTrials.gov v2

    func clinicalTrials(query: String?, id: String?, limit: Int, _ get: (String) async throws -> JSON) async throws -> String {
        let base = "https://clinicaltrials.gov/api/v2/studies"
        let studies: [JSON]
        if let id { studies = [try await get("\(base)/\(Self.q(id.uppercased()))?format=json")] }
        else { studies = try await get("\(base)?query.term=\(Self.q(query!))&pageSize=\(limit)&format=json")["studies"]?.arrayValue ?? [] }
        return studies.map { s in
            let p = s["protocolSection"]
            let nct = p?["identificationModule"]?.str("nctId") ?? "?"
            let title = p?["identificationModule"]?.str("briefTitle") ?? "?"
            let status = p?["statusModule"]?.str("overallStatus") ?? "?"
            let phases = (p?["designModule"]?["phases"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "/")
            let n = p?["designModule"]?["enrollmentInfo"]?["count"]?.numberValue.map { String(Int($0)) } ?? "?"
            let conditions = (p?["conditionsModule"]?["conditions"]?.arrayValue ?? []).compactMap(\.stringValue).prefix(4).joined(separator: ", ")
            let interventions = (p?["armsInterventionsModule"]?["interventions"]?.arrayValue ?? []).compactMap { $0.str("name") }.prefix(4).joined(separator: ", ")
            let sponsor = p?["sponsorCollaboratorsModule"]?["leadSponsor"]?.str("name") ?? ""
            let results = s["hasResults"]?.boolValue == true ? " · results posted" : ""
            return "\(nct) · \(title)\n  \(status) · \(phases.isEmpty ? "phase n/a" : phases) · n=\(n)\(results) · \(sponsor)\n  conditions: \(conditions)\n  interventions: \(interventions)\n  https://clinicaltrials.gov/study/\(nct)"
        }.joined(separator: "\n")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
