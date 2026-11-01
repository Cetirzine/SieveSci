import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(PDFKit)
import PDFKit
#endif

/// One bibliographic record in a task's library (a CSL-JSON-like subset).
public struct PaperRecord: Codable, Sendable, Equatable, Identifiable {
    public var id: String { key }
    public var key: String                // citation key, e.g. "smith2023crispr"
    public var title: String
    public var authors: [String]
    public var year: Int?
    public var venue: String?
    public var doi: String?
    public var pmid: String?
    public var pmcid: String?
    public var arxiv: String?
    public var url: String?
    public var abstract: String?
    public var oaPdfURL: String?
    public var pdfPath: String?           // relative to the library dir
    public var textPath: String?
    public var pdfSHA256: String?
    public var source: String             // openalex | europepmc | arxiv | crossref | manual
    public var addedAt: Date
    public var notes: String?
    /// Citation count when the source reports one (OpenAlex), with the date it was read.
    public var citedBy: Int? = nil
    public var openAlexId: String? = nil
}

/// Scholarly search + open-access download into a per-task library:
///
///   <workspace>/.sievesci/tasks/<task>/library/
///     library.json        records
///     references.bib      BibTeX (from Crossref content negotiation when a DOI exists)
///     pdf/<key>.pdf       open-access full texts only (OpenAlex best OA location, arXiv, PMC)
///     text/<key>.txt      extracted text, used for citation grounding
///
/// Only legal open-access sources are used; paywalled papers are recorded as metadata + abstract.
public final class LiteratureLibrary: @unchecked Sendable {
    public let dir: URL
    let http: HTTPStreaming
    let contactEmail: String
    public var openAlexKey: String?
    private let lock = NSLock()
    public private(set) var records: [PaperRecord] = []

    public init(dir: URL, contactEmail: String = "", http: HTTPStreaming = URLSessionStreaming()) throws {
        self.dir = dir
        self.http = http
        self.contactEmail = contactEmail
        for sub in ["pdf", "text"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: dir.appendingPathComponent("library.json")) {
            records = (try? dec.decode([PaperRecord].self, from: d)) ?? []
        }
    }

    /// Merges per-task libraries (from before libraries were shared) into the workspace library, once.
    static func adoptTaskLibraries(into shared: URL, tasks: URL) {
        let fm = FileManager.default
        let stamp = shared.appendingPathComponent(".adopted")
        guard !fm.fileExists(atPath: stamp.path) else { return }
        try? fm.createDirectory(at: shared, withIntermediateDirectories: true)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var merged = (try? Data(contentsOf: shared.appendingPathComponent("library.json"))).flatMap { try? dec.decode([PaperRecord].self, from: $0) } ?? []
        for task in (try? fm.contentsOfDirectory(at: tasks, includingPropertiesForKeys: nil)) ?? [] {
            let lib = task.appendingPathComponent("library")
            guard let d = try? Data(contentsOf: lib.appendingPathComponent("library.json")),
                  let rs = try? dec.decode([PaperRecord].self, from: d) else { continue }
            for r in rs where !merged.contains(where: { $0.key == r.key }) { merged.append(r) }
            for sub in ["pdf", "text"] {
                let from = lib.appendingPathComponent(sub), to = shared.appendingPathComponent(sub)
                try? fm.createDirectory(at: to, withIntermediateDirectories: true)
                for f in (try? fm.contentsOfDirectory(atPath: from.path)) ?? [] where !fm.fileExists(atPath: to.appendingPathComponent(f).path) {
                    try? fm.copyItem(at: from.appendingPathComponent(f), to: to.appendingPathComponent(f))
                }
            }
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try? enc.encode(merged).write(to: shared.appendingPathComponent("library.json"))
        try? Data().write(to: stamp)
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        lock.lock()
        let rs = records
        lock.unlock()
        try? enc.encode(rs).write(to: dir.appendingPathComponent("library.json"))
    }

    public func find(_ ref: String) -> PaperRecord? {
        let r = ref.lowercased().trimmingCharacters(in: .whitespaces)
        lock.lock(); defer { lock.unlock() }
        return records.first {
            $0.key.lowercased() == r || $0.doi?.lowercased() == r || $0.pmid == r || $0.arxiv?.lowercased() == r
                || $0.pmcid?.lowercased() == r
        }
    }

    // MARK: Search

    func get(_ url: String) async throws -> JSON {
        guard let u = URL(string: url) else { throw ToolError.invalidInput(url) }
        var req = URLRequest(url: u)
        req.setValue("SieveSci/\(SieveSci.version) (mailto:\(contactEmail))", forHTTPHeaderField: "user-agent")
        req.timeoutInterval = 30
        let (status, data) = try await http.send(req)
        guard status < 300 else { throw ProviderError.http(status: status, body: String(decoding: data.prefix(500), as: UTF8.self)) }
        return try JSONCodec.parse(data)
    }

    static func q(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s }

    /// OpenAlex (global, all disciplines, with OA locations) — the default source.
    public func searchOpenAlex(_ query: String, limit: Int = 10, fromYear: Int? = nil) async throws -> [PaperRecord] {
        var url = "https://api.openalex.org/works?search=\(Self.q(query))&per-page=\(limit)"
        if let y = fromYear { url += "&filter=from_publication_date:\(y)-01-01" }
        if !contactEmail.isEmpty { url += "&mailto=\(Self.q(contactEmail))" }
        // OpenAlex now meters anonymous use per IP; an API key (free) gives each user their own budget.
        if let k = openAlexKey { url += "&api_key=\(Self.q(k))" }
        let j = try await get(url)
        return (j["results"]?.arrayValue ?? []).map(Self.openAlexRecord)
    }

    static func openAlexRecord(_ w: JSON) -> PaperRecord {
        let authors = (w["authorships"]?.arrayValue ?? []).compactMap { $0["author"]?["display_name"]?.stringValue }
        let doi = w.str("doi")?.replacingOccurrences(of: "https://doi.org/", with: "")
        let ids = w["ids"]
        return PaperRecord(
            key: "", title: w.str("title") ?? w.str("display_name") ?? "", authors: authors, year: w.int("publication_year"),
            venue: w["primary_location"]?["source"]?["display_name"]?.stringValue, doi: doi,
            pmid: ids?["pmid"]?.stringValue?.components(separatedBy: "/").last,
            pmcid: ids?["pmcid"]?.stringValue?.components(separatedBy: "/").last, arxiv: nil,
            url: w.str("id"), abstract: invertedAbstract(w["abstract_inverted_index"]),
            oaPdfURL: w["best_oa_location"]?["pdf_url"]?.stringValue, pdfPath: nil, textPath: nil, pdfSHA256: nil,
            source: "openalex", addedAt: Date(), notes: nil,
            citedBy: w.int("cited_by_count"), openAlexId: w.str("id")?.components(separatedBy: "/").last)
    }

    private var openAlexAuth: String {
        (contactEmail.isEmpty ? "" : "&mailto=\(Self.q(contactEmail))") + (openAlexKey.map { "&api_key=\(Self.q($0))" } ?? "")
    }

    /// One OpenAlex work by DOI, PMID, OpenAlex id (W…) or library key.
    public func openAlexWork(_ ref: String) async throws -> JSON {
        var r = ref.trimmingCharacters(in: .whitespaces)
        if let rec = find(r) {
            if let w = rec.openAlexId { r = w } else if let d = rec.doi { r = d } else if let p = rec.pmid { r = "pmid:" + p }
        }
        let path: String
        if r.range(of: #"^W\d+$"#, options: .regularExpression) != nil { path = r } else {
            let (kind, v) = PaperRef.normalize(r)
            switch kind {
            case .doi: path = "doi:" + v
            case .pmid: path = "pmid:" + v
            case .pmcid: path = "pmcid:" + v
            case .arxiv: path = "doi:10.48550/arXiv." + v
            case .unknown: path = v
            }
        }
        let enc = (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path).replacingOccurrences(of: "%3A", with: ":")
        let auth = openAlexAuth
        return try await get("https://api.openalex.org/works/\(enc)" + (auth.isEmpty ? "" : "?" + auth.dropFirst()))
    }

    /// Works the given work cites (`references`) or that cite it (`citing`), most-cited first.
    public func openAlexNeighbors(of workId: String, direction: String, limit: Int, fromYear: Int? = nil) async throws -> [PaperRecord] {
        var filter = (direction == "references" ? "cited_by:" : "cites:") + workId
        if let y = fromYear { filter += ",from_publication_date:\(y)-01-01" }
        let j = try await get("https://api.openalex.org/works?filter=\(filter)&sort=cited_by_count:desc&per-page=\(limit)\(openAlexAuth)")
        return (j["results"]?.arrayValue ?? []).map(Self.openAlexRecord)
    }

    /// Europe PMC (biomedical; includes PubMed records and preprints).
    public func searchEuropePMC(_ query: String, limit: Int = 10) async throws -> [PaperRecord] {
        let j = try await get("https://www.ebi.ac.uk/europepmc/webservices/rest/search?query=\(Self.q(query))&format=json&resultType=core&pageSize=\(limit)")
        return (j["resultList"]?["result"]?.arrayValue ?? []).map { r in
            let authors = (r["authorList"]?["author"]?.arrayValue ?? []).compactMap { $0.str("fullName") }
            let pdf = (r["fullTextUrlList"]?["fullTextUrl"]?.arrayValue ?? []).first {
                $0.str("documentStyle") == "pdf" && $0.str("availabilityCode") == "OA"
            }?.str("url")
            return PaperRecord(
                key: "", title: r.str("title") ?? "", authors: authors, year: Int(r.str("pubYear") ?? ""),
                venue: r["journalInfo"]?["journal"]?["title"]?.stringValue, doi: r.str("doi"), pmid: r.str("pmid"),
                pmcid: r.str("pmcid"), arxiv: nil, url: r.str("doi").map { "https://doi.org/\($0)" },
                abstract: r.str("abstractText").map(HTMLText.extract), oaPdfURL: pdf, pdfPath: nil, textPath: nil, pdfSHA256: nil,
                source: "europepmc", addedAt: Date(), notes: nil)
        }
    }

    /// arXiv (physics, q-bio, cs, stats). Atom XML, parsed with regexes on the few fields needed.
    public func searchArXiv(_ query: String, limit: Int = 10) async throws -> [PaperRecord] {
        guard let u = URL(string: "https://export.arxiv.org/api/query?search_query=all:\(Self.q(query))&max_results=\(limit)") else { return [] }
        let (status, data) = try await http.send(URLRequest(url: u))
        guard status < 300 else { throw ProviderError.http(status: status, body: "") }
        let xml = String(decoding: data, as: UTF8.self)
        func all(_ pat: String, _ s: String) -> [String] {
            guard let re = try? NSRegularExpression(pattern: pat, options: [.dotMatchesLineSeparators]) else { return [] }
            return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range(at: 1), in: s).map { String(s[$0]) } }
        }
        return all("<entry>(.*?)</entry>", xml).map { e in
            let id = all("<id>https?://arxiv.org/abs/(.*?)</id>", e).first ?? ""
            let bare = id.replacingOccurrences(of: "v\\d+$", with: "", options: .regularExpression)
            let clean = { (s: String) in s.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            return PaperRecord(
                key: "", title: clean(all("<title>(.*?)</title>", e).first ?? ""), authors: all("<name>(.*?)</name>", e),
                year: Int((all("<published>(\\d{4})", e).first) ?? ""), venue: "arXiv", doi: all("<arxiv:doi[^>]*>(.*?)</arxiv:doi>", e).first,
                pmid: nil, pmcid: nil, arxiv: bare, url: "https://arxiv.org/abs/\(id)", abstract: clean(all("<summary>(.*?)</summary>", e).first ?? ""),
                oaPdfURL: "https://arxiv.org/pdf/\(id)", pdfPath: nil, textPath: nil, pdfSHA256: nil, source: "arxiv", addedAt: Date(), notes: nil)
        }
    }

    static func invertedAbstract(_ inv: JSON?) -> String? {
        guard let o = inv?.objectValue, !o.isEmpty else { return nil }
        var words: [(Int, String)] = []
        for (w, ps) in o { for p in ps.arrayValue ?? [] { if let i = p.intValue { words.append((i, w)) } } }
        return words.sorted { $0.0 < $1.0 }.map(\.1).joined(separator: " ")
    }

    // MARK: Library management

    /// Deterministic citation key: first-author surname + year + first title word.
    public func makeKey(_ r: PaperRecord) -> String {
        // Authors arrive as "Given Surname" (OpenAlex, arXiv) or "Surname II" (Europe PMC/PubMed).
        let tokens = (r.authors.first ?? "anon").split(separator: " ").map(String.init)
        let initialsLast = tokens.count > 1 && tokens.last!.count <= 3 && tokens.last! == tokens.last!.uppercased()
        let surname = ((initialsLast ? tokens.first : tokens.last) ?? "anon").lowercased()
            .folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter }
        let word = r.title.lowercased().split(whereSeparator: { !$0.isLetter }).first { $0.count > 3 && !["with", "from", "that", "this", "using"].contains(String($0)) }
        var key = "\(surname)\(r.year.map(String.init) ?? "nd")\(word.map(String.init) ?? "")"
        lock.lock()
        let existing = Set(records.map(\.key))
        lock.unlock()
        var suffix = 1
        let base = key
        while existing.contains(key) { suffix += 1; key = base + String(UnicodeScalar(UInt8(96 + min(suffix, 26)))) }
        return key
    }

    @discardableResult
    public func add(_ rec: PaperRecord) -> PaperRecord {
        if let doi = rec.doi, let existing = find(doi) { return existing }
        if let ax = rec.arxiv, let existing = find(ax) { return existing }
        var r = rec
        if r.key.isEmpty { r.key = makeKey(r) }
        lock.lock()
        records.append(r)
        lock.unlock()
        save()
        return r
    }

    /// Downloads the open-access PDF (if any), fingerprints it, and extracts text.
    public func download(_ key: String) async throws -> PaperRecord {
        guard var r = find(key) else { throw ToolError.invalidInput("no library entry \(key)") }
        if r.pdfPath != nil { return r }
        var candidates: [String] = []
        if let u = r.oaPdfURL { candidates.append(u) }
        if let pmc = r.pmcid { candidates.append("https://europepmc.org/articles/\(pmc)?pdf=render") }
        if let ax = r.arxiv { candidates.append("https://arxiv.org/pdf/\(ax)") }
        if let doi = r.doi, !contactEmail.isEmpty,
           let j = try? await get("https://api.unpaywall.org/v2/\(doi)?email=\(Self.q(contactEmail))"),
           let u = j["best_oa_location"]?["url_for_pdf"]?.stringValue {
            candidates.append(u)
        }
        for c in candidates {
            guard let u = URL(string: c) else { continue }
            var req = URLRequest(url: u)
            req.setValue("SieveSci/\(SieveSci.version) (mailto:\(contactEmail))", forHTTPHeaderField: "user-agent")
            req.timeoutInterval = 60
            guard let (status, data) = try? await http.send(req), status < 300, data.starts(with: Array("%PDF".utf8)) else { continue }
            let pdfRel = "pdf/\(r.key).pdf"
            try data.write(to: dir.appendingPathComponent(pdfRel))
            r.pdfPath = pdfRel
            r.pdfSHA256 = Hashing.sha256Hex(data)
            if let text = Self.extractText(dir.appendingPathComponent(pdfRel)), !text.isEmpty {
                let tRel = "text/\(r.key).txt"
                try text.write(to: dir.appendingPathComponent(tRel), atomically: true, encoding: .utf8)
                r.textPath = tRel
            }
            break
        }
        if r.pdfPath == nil, let pmc = r.pmcid, let text = await europePMCFullText(pmc), text.count > 2000 {
            // PMC open-access articles: the JATS XML full text is more reliable than scraping a PDF.
            let tRel = "text/\(r.key).txt"
            try text.write(to: dir.appendingPathComponent(tRel), atomically: true, encoding: .utf8)
            r.textPath = tRel
        } else if r.pdfPath == nil, let abs = r.abstract {
            // No OA full text: keep the abstract as the grounding text, clearly labelled.
            let tRel = "text/\(r.key).txt"
            try ("[abstract only — no open-access full text found]\n\n" + abs).write(to: dir.appendingPathComponent(tRel), atomically: true, encoding: .utf8)
            r.textPath = tRel
        }
        update(r)
        await fetchBibTeX(r.key)
        return find(r.key) ?? r
    }

    func update(_ r: PaperRecord) {
        lock.lock()
        if let i = records.firstIndex(where: { $0.key == r.key }) { records[i] = r }
        lock.unlock()
        save()
    }

    func europePMCFullText(_ pmcid: String) async -> String? {
        guard let u = URL(string: "https://www.ebi.ac.uk/europepmc/webservices/rest/\(pmcid)/fullTextXML"),
              let (s, d) = try? await http.send(URLRequest(url: u)), s < 300 else { return nil }
        let xml = String(decoding: d, as: UTF8.self)
        let body = xml.replacingOccurrences(of: "(?s)<ref-list.*?</ref-list>", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "</(p|title|sec|caption)>", with: "\n\n", options: .regularExpression)
        return HTMLText.extract(body)
    }

    /// Crossref metadata for DOIs that neither Europe PMC nor OpenAlex resolved.
    public func crossref(doi: String) async throws -> PaperRecord? {
        let j = try await get("https://api.crossref.org/works/\(doi)")
        guard let m = j["message"] else { return nil }
        let authors = (m["author"]?.arrayValue ?? []).map { "\($0.str("given") ?? "") \($0.str("family") ?? "")".trimmingCharacters(in: .whitespaces) }
        let year = m["issued"]?["date-parts"]?[0]?[0]?.intValue
        return PaperRecord(key: "", title: m["title"]?[0]?.stringValue ?? "", authors: authors, year: year, venue: m["container-title"]?[0]?.stringValue,
                           doi: doi, pmid: nil, pmcid: nil, arxiv: nil, url: "https://doi.org/\(doi)", abstract: m.str("abstract").map(HTMLText.extract),
                           oaPdfURL: nil, pdfPath: nil, textPath: nil, pdfSHA256: nil, source: "crossref", addedAt: Date(), notes: nil)
    }

    public static func extractText(_ pdf: URL) -> String? {
        #if canImport(PDFKit)
        return PDFDocument(url: pdf)?.string
        #else
        guard ProcessRunner.which("pdftotext") != nil else { return nil }
        let out = pdf.deletingPathExtension().appendingPathExtension("tmp.txt")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ProcessRunner.which("pdftotext")!)
        p.arguments = ["-layout", pdf.path, out.path]
        try? p.run()
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(at: out) }
        return try? String(contentsOf: out, encoding: .utf8)
        #endif
    }

    public func text(_ key: String) -> String? {
        guard let r = find(key), let t = r.textPath else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(t), encoding: .utf8)
    }

    // MARK: BibTeX

    /// Crossref content negotiation gives publisher-quality BibTeX for DOIs; otherwise one is built.
    public func fetchBibTeX(_ key: String) async {
        guard let r = find(key) else { return }
        var entry: String?
        if let doi = r.doi, let u = URL(string: "https://doi.org/\(doi)") {
            var req = URLRequest(url: u)
            req.setValue("application/x-bibtex", forHTTPHeaderField: "accept")
            req.timeoutInterval = 20
            if let (s, d) = try? await http.send(req), s < 300 {
                let b = String(decoding: d, as: UTF8.self)
                // Re-key to the library key so [@key] citations resolve.
                entry = b.replacingOccurrences(of: "^\\s*@(\\w+)\\{[^,]*,", with: "@$1{\(r.key),", options: .regularExpression)
            }
        }
        appendBib(entry ?? Self.bibtex(r), key: r.key)
    }

    func appendBib(_ entry: String, key: String) {
        let url = dir.appendingPathComponent("references.bib")
        var existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        if existing.contains("{\(key),") { return }
        existing += (existing.isEmpty ? "" : "\n") + entry.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        try? existing.write(to: url, atomically: true, encoding: .utf8)
    }

    public static func bibtex(_ r: PaperRecord) -> String {
        var f = ["title = {\(r.title)}", "author = {\(r.authors.joined(separator: " and "))}"]
        if let y = r.year { f.append("year = {\(y)}") }
        if let v = r.venue { f.append("journal = {\(v)}") }
        if let d = r.doi { f.append("doi = {\(d)}") }
        if let a = r.arxiv { f.append("eprint = {\(a)}"); f.append("archivePrefix = {arXiv}") }
        if let p = r.pmid { f.append("pmid = {\(p)}") }
        if let u = r.url { f.append("url = {\(u)}") }
        return "@article{\(r.key),\n  " + f.joined(separator: ",\n  ") + "\n}"
    }
}

/// Normalizes the many ways papers are referenced ("doi:", "https://doi.org/…", "PMID: 123", "PMC123", "arXiv:2401.01234v2").
public enum PaperRef {
    public enum Kind: String { case doi, pmid, pmcid, arxiv, unknown }

    public static func normalize(_ raw: String) -> (Kind, String) {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for p in ["https://doi.org/", "http://doi.org/", "https://dx.doi.org/", "doi:", "DOI:", "DOI "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        if s.hasPrefix("10.") { return (.doi, s) }
        if let m = Grounding.matches(#"(?i)^(?:pmid:?\s*)?(\d{5,9})$"#, in: s, group: 1).first { return (.pmid, m) }
        if let m = Grounding.matches(#"(?i)^(?:pmcid:?\s*)?(PMC\d+)$"#, in: s, group: 1).first { return (.pmcid, m.uppercased()) }
        if let m = Grounding.matches(#"(?i)^(?:arxiv:\s*)?(\d{4}\.\d{4,5})(?:v\d+)?$"#, in: s, group: 1).first { return (.arxiv, m) }
        return (.unknown, s)
    }
}
