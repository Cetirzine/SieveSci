import Foundation
import Testing
@testable import SieveSciCore

/// Regression: adding an arXiv preprint to the library always failed.
///
/// The tool asked the API for `search_query=all:id:<id>`, which arXiv rejects with `HTTP 400` — a bare id is
/// not a search term. Ids must go through `id_list`. The same failure hit `verify_citation`, and arXiv's own
/// `10.48550/arXiv.…` DOIs were routed to Crossref, which does not mint them (DataCite does) and answers 404.
@Suite struct ArxivResolution {
    static let titans = """
    <?xml version="1.0" encoding="UTF-8"?>
    <feed xmlns="http://www.w3.org/2005/Atom" xmlns:arxiv="http://arxiv.org/schemas/atom">
      <title>arXiv Query: search_query=&amp;id_list=2501.00663</title>
      <entry>
        <id>http://arxiv.org/abs/2501.00663v1</id>
        <published>2025-01-01T00:00:00Z</published>
        <title>Titans: Learning to Memorize at Test Time</title>
        <summary>We introduce a new long-term memory module.</summary>
        <author><name>Ali Behrouz</name></author>
        <arxiv:doi>10.48550/arXiv.2501.00663</arxiv:doi>
      </entry>
    </feed>
    """

    static let openAlexWork = #"{"id":"https://openalex.org/W4406032263","doi":"https://doi.org/10.48550/arXiv.2501.00663","title":"Titans: Learning to Memorize at Test Time","publication_year":2025,"cited_by_count":12,"authorships":[{"author":{"display_name":"Ali Behrouz"}}],"primary_location":{"source":{"display_name":"arXiv"}}}"#

    /// One paper by id must ask for `id_list`; the search form is what arXiv refuses.
    @Test func lookupUsesIdListNotASearchQuery() async throws {
        let http = RoutedHTTP([("export.arxiv.org", Self.titans)])
        let lib = try Self.library(http)
        let rec = try await lib.arxivById("2501.00663")
        #expect(rec?.arxiv == "2501.00663")
        #expect(rec?.title == "Titans: Learning to Memorize at Test Time")
        let url = try #require(http.urls.first)
        let decoded = url.removingPercentEncoding ?? url
        #expect(decoded.contains("id_list=2501.00663"))
        #expect(!url.contains("search_query=all:id"))
    }

    @Test func arxivDoiIsNormalizedToAPreprintId() {
        #expect(PaperRef.normalize("10.48550/arXiv.2501.00663").0 == .arxiv)
        #expect(PaperRef.normalize("10.48550/arXiv.2501.00663").1 == "2501.00663")
        // Case and version suffixes turn up in model output.
        #expect(PaperRef.normalize("10.48550/arxiv.2501.00663v2").1 == "2501.00663")
        // A journal DOI that Crossref does mint must stay a DOI.
        #expect(PaperRef.normalize("10.18653/v1/2026.findings-acl.1989").0 == .doi)
    }

    @Test func paperFetchAddsAnArxivPreprint() async throws {
        let http = RoutedHTTP([("export.arxiv.org", Self.titans)])
        let (ctx, s) = try toolContext(http: http)
        let out = try await PaperFetchTool().run(["ref": "arXiv:2501.00663"], ctx)
        #expect(!out.isError, "\(out.text) \(http.urls)")
        #expect(s.library.find("2501.00663") != nil)
        #expect(http.urls.contains { ($0.removingPercentEncoding ?? $0).contains("id_list=2501.00663") })
    }

    /// When arXiv itself is unreachable or throttling, the same id still resolves through OpenAlex's DOI index.
    @Test func arxivIdFallsBackToOpenAlex() async throws {
        let http = RoutedHTTP([("api.openalex.org/works/doi:10.48550/arXiv.2501.00663", Self.openAlexWork)])
        let (ctx, s) = try toolContext(http: http)
        let out = try await PaperFetchTool().run(["ref": "10.48550/arXiv.2501.00663"], ctx)
        #expect(!out.isError, "\(out.text) \(http.urls)")
        #expect(s.library.find("10.48550/arXiv.2501.00663") != nil)
    }

    /// Regression (0.2.3): the arXiv API only reports `<arxiv:doi>` when the authors attached a journal DOI, so
    /// preprints fetched straight from arXiv had no DOI and the inspector showed no DOI link.
    @Test func arxivPreprintWithoutJournalDoiGetsItsDataCiteDoi() async throws {
        let feed = Self.titans.replacingOccurrences(of: "<arxiv:doi>10.48550/arXiv.2501.00663</arxiv:doi>", with: "")
        let lib = try Self.library(RoutedHTTP([("export.arxiv.org", feed)]))
        let rec = try #require(try await lib.arxivById("2501.00663"))
        #expect(rec.doi == "10.48550/arXiv.2501.00663")
        #expect(lib.add(rec).doi == "10.48550/arXiv.2501.00663")
    }

    @Test func openAlexArxivRecordKeepsBothIdentifiers() throws {
        let r = LiteratureLibrary.openAlexRecord(try JSONCodec.parse(Self.openAlexWork))
        #expect(r.doi == "10.48550/arXiv.2501.00663")
        #expect(r.arxiv == "2501.00663")
        // A journal DOI is never overwritten by the preprint one.
        var j = PaperRecord(key: "", title: "t", authors: [], year: nil, venue: nil, doi: "10.1038/x", pmid: nil, pmcid: nil,
                            arxiv: "2501.00663", url: nil, abstract: nil, oaPdfURL: nil, pdfPath: nil, textPath: nil,
                            pdfSHA256: nil, source: "arxiv", addedAt: Date(), notes: nil)
        j = j.withArxivIdentifiers()
        #expect(j.doi == "10.1038/x")
        #expect(PaperRef.normalize("arXiv:hep-th/9901001v2").1 == "hep-th/9901001")
    }

    private static func library(_ http: HTTPStreaming) throws -> LiteratureLibrary {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-lib-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try LiteratureLibrary(dir: dir, http: http)
    }
}
