import Foundation

/// Detects assertions that are not backed by evidence the host has actually seen.
///
/// Two deterministic checks (no model call, so they cost nothing and run on every final answer):
/// - **Citations**: every `[@key]` must resolve to an entry in the task library; DOIs / PMIDs /
///   arXiv ids mentioned in prose must either be in the library or appear in a search receipt.
///   A citation of something never retrieved is the classic fabricated reference.
/// - **Numbers**: statistics stated as results (p-values, fold changes, percentages, r/R², IC50,
///   Kd, AUC …) must appear in some tool output (receipt corpus) or in a cited paper's text.
///   Numbers that appear nowhere are flagged as possibly hallucinated.
///
/// Findings are not verdicts: they trigger the checker agent, which reads the evidence and decides.
public struct GroundingReport: Sendable, Equatable {
    public var unresolvedCitations: [String] = []
    public var unretrievedIdentifiers: [String] = []
    public var unsupportedNumbers: [String] = []
    public var citationCount = 0

    public var isClean: Bool { unresolvedCitations.isEmpty && unretrievedIdentifiers.isEmpty && unsupportedNumbers.isEmpty }

    public var summary: String {
        var parts: [String] = []
        if !unresolvedCitations.isEmpty { parts.append("citations not in the library: \(unresolvedCitations.joined(separator: ", "))") }
        if !unretrievedIdentifiers.isEmpty { parts.append("identifiers never retrieved: \(unretrievedIdentifiers.joined(separator: ", "))") }
        if !unsupportedNumbers.isEmpty { parts.append("numbers found in no tool output or cited text: \(unsupportedNumbers.joined(separator: ", "))") }
        return parts.joined(separator: "; ")
    }
}

public enum Grounding {
    public static let citationPattern = #"\[@([A-Za-z0-9_:\-\.]+)(?:[^\]]*)\]"#
    public static let doiPattern = #"\b10\.\d{4,9}/[-._;()/:A-Za-z0-9]*[A-Za-z0-9]"#
    public static let arxivPattern = #"(?i)\barXiv:\s?(\d{4}\.\d{4,5})(?:v\d+)?"#
    public static let pmidPattern = #"(?i)\bPMID:?\s*(\d{6,9})\b"#
    /// "Smith et al. (2019)", "Smith et al., 2019", "(Smith et al. 2019, Nature)".
    public static let authorYearPattern = #"\b(\p{Lu}[\p{Ll}'\-]+(?:\s(?:and|&)\s\p{Lu}[\p{Ll}'\-]+)?)\s+et\s+al\.?,?\s*\(?((?:19|20)\d{2})[a-z]?\b"#
    /// Result-like numbers: a statistic keyword followed (closely) by a number.
    public static let statPattern = #"(?i)\b(p|q|padj|FDR|r|R\^?2|R²|ρ|rho|AUC|IC50|EC50|Kd|Ki|log2FC|fold[- ]change|OR|HR|accuracy|F1|RMSD|ΔG)\s*(?:value)?\s*[=<>≈≤≥:]\s*(-?\d+(?:\.\d+)?(?:e-?\d+)?(?:\s*×\s*10\^?-?\d+)?)"#
    public static let percentPattern = #"(-?\d+(?:\.\d+)?)\s?%"#

    public static func matches(_ pattern: String, in s: String, group: Int = 0) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap {
            Range($0.range(at: min(group, $0.numberOfRanges - 1)), in: s).map { String(s[$0]) }
        }
    }

    /// Normalizes a numeric literal so "0.050", "5e-2" and "5.0×10^-2" compare equal-ish.
    static func numericForms(_ raw: String) -> [String] {
        var forms = [raw]
        let compact = raw.replacingOccurrences(of: " ", with: "")
        forms.append(compact)
        if let d = Double(compact.replacingOccurrences(of: "×10^", with: "e").replacingOccurrences(of: "×10", with: "e")) {
            forms.append(String(d))
            for digits in 2...4 { forms.append(String(format: "%.\(digits)g", d)); forms.append(String(format: "%.\(digits)f", d)) }
            forms.append(String(format: "%.3e", d))
        }
        return Array(Set(forms))
    }

    /// Removes fenced and inline code, where citation-like text is usually meta-discussion or code.
    static func stripCode(_ s: String) -> String {
        s.replacingOccurrences(of: "(?s)```.*?```", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "`[^`\n]*`", with: " ", options: .regularExpression)
    }

    public static func check(text raw: String, library: LiteratureLibrary?, evidenceCorpus: String) -> GroundingReport {
        let text = stripCode(raw)
        var rep = GroundingReport()
        let cites = matches(citationPattern, in: text, group: 1)
        rep.citationCount = cites.count
        rep.unresolvedCitations = Array(Set(cites.filter { library?.find($0) == nil })).sorted()

        var ids = matches(doiPattern, in: text).map { $0.lowercased() }
        ids += matches(arxivPattern, in: text, group: 1)
        ids += matches(pmidPattern, in: text, group: 1)
        let corpusLower = evidenceCorpus.lowercased()
        var unretrieved = Set(ids.filter { library?.find($0) == nil && !corpusLower.contains($0.lowercased()) })
        // Author–year citations: some library paper by that author and year, or a search result naming them.
        for m in CodePaperLinker.matchGroups(authorYearPattern, text) where m.count >= 3 {
            let surname = String(m[1].split(separator: " ").first ?? ""), year = Int(m[2])
            let inLibrary = library?.records.contains { r in r.year == year && r.authors.contains { $0.localizedCaseInsensitiveContains(surname) } } ?? false
            let inCorpus = corpusLower.contains(surname.lowercased()) && corpusLower.contains(m[2])
            if !inLibrary && !inCorpus { unretrieved.insert("\(surname) et al. \(m[2])") }
        }
        rep.unretrievedIdentifiers = unretrieved.sorted()

        // Evidence = tool outputs + text of cited papers.
        var evidence = evidenceCorpus
        for k in cites { if let t = library?.text(k) { evidence += "\n" + t } }
        let stats = matches(statPattern, in: text, group: 2)
        let pcts = matches(percentPattern, in: text, group: 1)
        for n in Set(stats + pcts) {
            // Round, small numbers (e.g. "95%", "5%") are too generic to check meaningfully.
            if let d = Double(n), d == d.rounded(), abs(d) <= 100, pcts.contains(n), !stats.contains(n) { continue }
            if !numericForms(n).contains(where: { evidence.contains($0) }) { rep.unsupportedNumbers.append(n) }
        }
        rep.unsupportedNumbers.sort()
        return rep
    }
}

/// Regex index linking papers to the code that implements them, both directions.
///
/// Recognized markers in source files (any comment syntax):
///   `@cite <key> [§section | eq. N | Alg. N]`   — explicit link to a library entry
///   DOIs (`10.xxxx/...`), `arXiv:2401.01234`, `PMID: 12345678` — resolved against the library
/// The agent is instructed to annotate every function that implements a published method this way,
/// so a reviewer can jump from a paper to its implementation and from code to its source.
public struct CodePaperLink: Codable, Sendable, Equatable {
    public var paperKey: String?
    public var identifier: String
    public var file: String
    public var line: Int
    public var locator: String?     // "§2.3", "eq. 4", …
    public var snippet: String
}

public enum CodePaperLinker {
    static let citeMarker = #"@cite\s+([A-Za-z0-9_:\-\.]+)(?:\s+((?:§|sec\.?|eq\.?|Eq\.?|Alg\.?|Fig\.?|Table)\s*[\w\.\-]+))?"#
    static let codeExtensions: Set<String> = ["py", "r", "R", "jl", "ipynb", "swift", "m", "sh", "c", "cpp", "h", "rs", "go", "js", "ts", "java", "scala", "nf", "smk", "wdl", "md", "qmd", "rmd", "Rmd"]

    public static func scan(workspace: URL, library: LiteratureLibrary?, maxFiles: Int = 5000) -> [CodePaperLink] {
        var links: [CodePaperLink] = []
        guard let en = FileManager.default.enumerator(at: workspace, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var seen = 0
        for case let url as URL in en {
            if ["node_modules", ".build", "__pycache__", ".venv", "venv"].contains(url.lastPathComponent) { en.skipDescendants(); continue }
            guard codeExtensions.contains(url.pathExtension),
                  (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 < 2_000_000,
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            seen += 1
            if seen > maxFiles { break }
            let rel = String(url.path.dropFirst(workspace.path.count + 1))
            for (i, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let l = String(line)
                guard l.contains("@cite") || l.contains("10.") || l.lowercased().contains("arxiv") || l.contains("PMID") else { continue }
                for m in matchGroups(citeMarker, l) {
                    links.append(CodePaperLink(paperKey: library?.find(m[1])?.key, identifier: m[1], file: rel, line: i + 1,
                                               locator: m.count > 2 && !m[2].isEmpty ? m[2] : nil, snippet: l.trimmingCharacters(in: .whitespaces)))
                }
                for id in Grounding.matches(Grounding.doiPattern, in: l) + Grounding.matches(Grounding.arxivPattern, in: l, group: 1)
                    + Grounding.matches(Grounding.pmidPattern, in: l, group: 1) where !l.contains("@cite") {
                    links.append(CodePaperLink(paperKey: library?.find(id)?.key, identifier: id, file: rel, line: i + 1, locator: nil,
                                               snippet: l.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return links
    }

    static func matchGroups(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { m in
            (0..<m.numberOfRanges).map { Range(m.range(at: $0), in: s).map { String(s[$0]) } ?? "" }
        }
    }
}
