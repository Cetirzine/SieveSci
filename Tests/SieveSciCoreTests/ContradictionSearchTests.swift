import Foundation
import Testing
@testable import SieveSciCore

@Suite struct ContradictionSearch {
    private func library(_ papers: [(String, String)]) throws -> ToolContext {
        let (ctx, s) = try toolContext(http: RoutedHTTP([]))
        let dir = s.library.dir
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("text"), withIntermediateDirectories: true)
        for (key, text) in papers {
            try text.write(to: dir.appendingPathComponent("text/\(key).txt"), atomically: true, encoding: .utf8)
            s.library.add(PaperRecord(key: key, title: key, authors: [], year: 2020, venue: nil, doi: nil, pmid: nil, pmcid: nil, arxiv: nil, url: nil,
                                      abstract: nil, oaPdfURL: nil, pdfPath: nil, textPath: "text/\(key).txt", pdfSHA256: nil,
                                      source: "manual", addedAt: Date(), notes: nil))
        }
        return ctx
    }

    static let papers = [
        ("support2019", "Oral metformin reduced tumour growth in xenograft mice by 40% relative to vehicle, with a clear dose response across three dose levels and no weight loss in the treated animals."),
        ("replication2021", "In an independent cohort we failed to replicate the reduction in tumour growth reported for metformin in xenograft mice; tumour volumes at day 21 were similar across arms."),
        ("unrelated2020", "Dietary fibre had no significant effect on gut transit time in healthy adult volunteers over twelve weeks of supplementation in this randomised crossover trial."),
    ]

    @Test func findsTheFailedReplicationOnly() async throws {
        let ctx = try library(Self.papers)
        let out = try await LibrarySearchTool().run(["query": "metformin reduces tumour growth in xenograft mice", "stance": "contradicting"], ctx)
        #expect(out.text.contains("[@replication2021]"))
        #expect(out.text.contains("cue: “failed to replicate”"))
        #expect(!out.text.contains("[@support2019]"), "agreeing passages are not contradictions")
        #expect(!out.text.contains("[@unrelated2020]"), "a null result on another topic is not a contradiction")
    }

    @Test func saysWhenNothingContradicts() async throws {
        let ctx = try library(Array(Self.papers.prefix(1)))
        let out = try await LibrarySearchTool().run(["query": "metformin tumour growth xenograft", "stance": "contradicting"], ctx)
        #expect(out.text.hasPrefix("No passage in the library contradicts this"))
        #expect(out.text.contains("paper_graph"))
    }

    @Test func defaultStanceIsUnchanged() async throws {
        let ctx = try library(Self.papers)
        let out = try await LibrarySearchTool().run(["query": "metformin tumour growth xenograft"], ctx)
        #expect(out.text.contains("[@support2019]") && out.text.contains("[@replication2021]"))
    }
}
