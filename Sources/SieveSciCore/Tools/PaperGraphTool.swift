import Foundation

// MARK: - Citation graph (PaperQA2-style citation traversal over OpenAlex)

/// Follows a paper's references backwards and its citing papers forwards. Forward citations are
/// where replications, corrections and rebuttals appear, so this is part of checking a finding,
/// not only of finding more papers.
struct PaperGraphTool: Tool {
    let name = "paper_graph"
    let description = """
    Citation graph of one paper (OpenAlex): its citation count and recent citations per year, whether it \
    is retracted, the works it cites (`references`) and the works citing it (`citing`, where replications \
    and rebuttals appear), each with ids and citation counts, most-cited first. ref: DOI, PMID, OpenAlex id \
    (W…) or a library [@key]. Add papers you rely on with `paper_fetch`.
    """
    var inputSchema: JSON {
        Schema.object(["ref": Schema.string("DOI, PMID, OpenAlex W-id or library key"),
                       "direction": Schema.stringEnum("Default both", ["both", "references", "citing"]),
                       "limit": Schema.integer("Per direction, default 10, max 50"),
                       "from_year": Schema.integer("citing only: earliest publication year")], required: ["ref"])
    }
    func effect(for input: JSON) -> ToolEffect { .readOnly }

    static func line(_ r: PaperRecord) -> String {
        let ids = [r.doi.map { "doi:\($0)" }, r.pmid.map { "pmid:\($0)" }, r.openAlexId].compactMap { $0 }.joined(separator: " ")
        let authors = r.authors.prefix(2).joined(separator: ", ") + (r.authors.count > 2 ? " et al." : "")
        return "- \(r.title) — \(authors) (\(r.year.map(String.init) ?? "n.d."))\(r.citedBy.map { " · cited \($0)×" } ?? "")\n  \(ids)"
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let ref = try input.required("ref")
        let lib = ctx.services.library
        let direction = input.str("direction") ?? "both"
        let limit = max(1, min(input.int("limit") ?? 10, 50))
        let w: JSON
        do { w = try await lib.openAlexWork(ref.replacingOccurrences(of: "[@", with: "").replacingOccurrences(of: "]", with: "")) } catch ProviderError.http(let status, _) {
            return .error(status == 404 ? "OpenAlex has no work for “\(ref)”." : "OpenAlex is unavailable (HTTP \(status)).")
        }
        let seed = LiteratureLibrary.openAlexRecord(w)
        guard let wid = seed.openAlexId else { return .error("OpenAlex returned no id for “\(ref)”.") }
        var out = "\(seed.title) (\(seed.year.map(String.init) ?? "n.d."), \(seed.venue ?? "?"))\n"
        out += "cited \(seed.citedBy ?? 0)× · references \(w["referenced_works"]?.arrayValue?.count ?? 0)"
        let byYear = (w["counts_by_year"]?.arrayValue ?? []).prefix(5).compactMap { y -> String? in
            guard let yr = y.int("year"), let n = y.int("cited_by_count") else { return nil }
            return "\(yr): \(n)"
        }
        if !byYear.isEmpty { out += " · recent citations " + byYear.joined(separator: ", ") }
        if w["is_retracted"]?.boolValue == true { out += "\n⚠ RETRACTED according to OpenAlex — do not rely on this paper's findings." }
        var errors: [String] = []
        if direction != "citing" {
            do {
                let refs = try await lib.openAlexNeighbors(of: wid, direction: "references", limit: limit)
                out += "\n\nReferences (most-cited first):\n" + (refs.isEmpty ? "(none indexed)" : refs.map(Self.line).joined(separator: "\n"))
            } catch { errors.append("references: \(error.localizedDescription)") }
        }
        if direction != "references" {
            do {
                let citing = try await lib.openAlexNeighbors(of: wid, direction: "citing", limit: limit, fromYear: input.int("from_year"))
                out += "\n\nCited by (most-cited first):\n" + (citing.isEmpty ? "(no citing works indexed)" : citing.map(Self.line).joined(separator: "\n"))
            } catch { errors.append("citing: \(error.localizedDescription)") }
        }
        if !errors.isEmpty { out += "\n\n(partial: \(errors.joined(separator: "; ")))" }
        ctx.services.emit(.literature(agentId: ctx.sessionId, action: .searched, key: wid, title: seed.title, detail: "citation graph"))
        return ToolOutput(out)
    }
}
