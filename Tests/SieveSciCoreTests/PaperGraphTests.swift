import Foundation
import Testing
@testable import SieveSciCore

@Suite struct PaperGraph {
    static let work = #"{"id":"https://openalex.org/W100","doi":"https://doi.org/10.1000/seed","title":"Seed paper","publication_year":2015,"cited_by_count":420,"is_retracted":true,"referenced_works":["https://openalex.org/W1","https://openalex.org/W2"],"counts_by_year":[{"year":2026,"cited_by_count":12},{"year":2025,"cited_by_count":30}],"authorships":[{"author":{"display_name":"Ana Lee"}}],"primary_location":{"source":{"display_name":"Nature"}}}"#
    static let refs = #"{"results":[{"id":"https://openalex.org/W1","doi":"https://doi.org/10.1000/older","title":"Older method","publication_year":2010,"cited_by_count":900,"authorships":[]}]}"#
    static let citing = #"{"results":[{"id":"https://openalex.org/W7","doi":"https://doi.org/10.1000/rebut","title":"A failed replication","publication_year":2020,"cited_by_count":15,"authorships":[{"author":{"display_name":"Bo Chen"}}]}]}"#

    @Test func followsReferencesAndCitations() async throws {
        let http = RoutedHTTP([("works/doi:10.1000/seed", Self.work), ("filter=cited_by:W100", Self.refs), ("filter=cites:W100", Self.citing)])
        let (ctx, _) = try toolContext(http: http)
        let out = try await PaperGraphTool().run(["ref": "https://doi.org/10.1000/seed"], ctx)
        #expect(out.text.hasPrefix("Seed paper (2015, Nature)"), "\(http.urls) \(out.text)")
        #expect(out.text.contains("cited 420× · references 2 · recent citations 2026: 12, 2025: 30"))
        #expect(out.text.contains("⚠ RETRACTED"))
        #expect(out.text.contains("- Older method —  (2010) · cited 900×"))
        #expect(out.text.contains("- A failed replication — Bo Chen (2020) · cited 15×\n  doi:10.1000/rebut W7"))
        #expect(http.urls.allSatisfy { $0.contains("api.openalex.org") })
    }

    @Test func libraryKeyResolvesToItsIdentifier() async throws {
        let http = RoutedHTTP([("works/doi:10.1000/seed", Self.work), ("filter=cites:W100", Self.citing)])
        let (ctx, s) = try toolContext(http: http)
        s.library.add(PaperRecord(key: "lee2015seed", title: "Seed paper", authors: ["Ana Lee"], year: 2015, venue: nil, doi: "10.1000/seed", pmid: nil,
                                  pmcid: nil, arxiv: nil, url: nil, abstract: nil, oaPdfURL: nil, pdfPath: nil, textPath: nil, pdfSHA256: nil,
                                  source: "manual", addedAt: Date(), notes: nil))
        let out = try await PaperGraphTool().run(["ref": "[@lee2015seed]", "direction": "citing"], ctx)
        #expect(!out.isError)
        #expect(!out.text.contains("References"))
        #expect(out.text.contains("A failed replication"))
    }

    @Test func unknownWork() async throws {
        let (ctx, _) = try toolContext(http: RoutedHTTP([]))
        let out = try await PaperGraphTool().run(["ref": "10.1000/nothing"], ctx)
        #expect(out.isError && out.text.contains("OpenAlex has no work"))
    }
}
