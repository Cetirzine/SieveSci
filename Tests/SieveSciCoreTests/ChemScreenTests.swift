import Foundation
import Testing
@testable import SieveSciCore

// The screen is tested against a stand-in list of everyday compounds (caffeine), never against the
// real controlled-substance list: what matters is that matching is by structure, not by spelling.

private let caffeineKey = "RYYVLZVUVIJVGH-UHFFFAOYSA-N"
private let standIn = ChemScreen(entries: [
    .init(cas: "58-08-2", source: "test list", smiles: "CN1C=NC2=C1C(=O)N(C(=O)N2C)C", inchikey: caffeineKey),
])

private func props(_ cid: Int, _ key: String, _ name: String) -> String {
    #"{"PropertyTable":{"Properties":[{"CID":\#(cid),"MolecularFormula":"X","MolecularWeight":"1","IUPACName":"\#(name)","InChIKey":"\#(key)"}]}}"#
}

/// PubChem resolves every caffeine spelling to the same compound; "caffeine citrate" is a separate
/// mixture CID whose parent is caffeine.
private let pubchem: [(String, String)] = [
    ("/compound/smiles/", props(2519, caffeineKey, "caffeine")),
    ("/compound/name/caffeine%20citrate/property", props(9001, "AAAAAAAAAAAAAA-UHFFFAOYSA-N", "caffeine citrate")),
    ("/compound/cid/9001/cids/JSON?cids_type=parent", #"{"IdentifierList":{"CID":[2519]}}"#),
    ("/compound/cid/2519/property/InChIKey", props(2519, caffeineKey, "caffeine")),
    ("/compound/name/aspirin/property", props(2244, "BSYNRYMUTXBXSQ-UHFFFAOYSA-N", "2-acetyloxybenzoic acid")),
    ("/compound/cid/2244/cids/JSON?cids_type=parent", #"{"IdentifierList":{"CID":[2244]}}"#),
    ("/synonyms/", #"{"InformationList":{"Information":[{"Synonym":[]}]}}"#),
]

private func context(_ http: HTTPStreaming) throws -> (ToolContext, SessionServices) { try toolContext(http: http) }

private func flags(_ s: SessionServices) throws -> [AuditLog.Entry] {
    try AuditLog.read(s.audit.url).filter { $0.kind == "chem_safety_flag" }
}

private func tool(local: @escaping @Sendable (String) async -> [String]? = { _ in nil }) -> ChemLookupTool {
    var t = ChemLookupTool()
    t.screen = standIn
    t.localKeys = local
    return t
}

@Suite struct ChemScreening {
    @Test func alternativeSpellingsAreCaughtByStructure() async throws {
        let spellings = ["Cn1cnc2c1c(=O)n(C)c(=O)n2C",          // aromatic form
                         "O=C1N(C)C(=O)c2n(C)cnc2N1C",           // different atom order
                         "CN1C(=O)N(C)c2ncn(C)c2C1=O",           // another traversal
                         "[CH3]N1C=NC2=C1C(=O)N(C(=O)N2C)C"]     // explicit hydrogens
        for smi in spellings {
            #expect(standIn.match(smiles: [smi]) == nil, "the text alone must not match, or this test proves nothing")
            let http = RoutedHTTP(pubchem)
            let (ctx, s) = try context(http)
            let out = try await tool().run(["query": .string(smi)], ctx)
            #expect(out.text.hasPrefix("⚠ CONTROLLED SUBSTANCE"), "\(smi) slipped past the screen")
            let f = try #require(try flags(s).first)
            #expect(f.data["basis"]?.stringValue == "inchikey")
            #expect(f.data["cas"]?.stringValue == "58-08-2")
        }
    }

    @Test func saltFormIsCaughtThroughItsParent() async throws {
        let (ctx, s) = try context(RoutedHTTP(pubchem))
        let out = try await tool().run(["query": "caffeine citrate"], ctx)
        #expect(out.text.hasPrefix("⚠ CONTROLLED SUBSTANCE"))
        #expect(try flags(s).count == 1)
    }

    @Test func stereoVariantIsCaughtByConnectivity() {
        let hit = standIn.match(inchikeys: ["RYYVLZVUVIJVGH-ZZZZZZZZSA-N"])
        #expect(hit?.basis == .connectivity)
        #expect(standIn.match(inchikeys: ["BSYNRYMUTXBXSQ-UHFFFAOYSA-N"]) == nil)
    }

    @Test func harmlessCompoundIsNotFlagged() async throws {
        let (ctx, s) = try context(RoutedHTTP(pubchem))
        let out = try await tool().run(["query": "aspirin"], ctx)
        #expect(!out.isError)
        #expect(!out.text.contains("CONTROLLED"))
        #expect(out.text.contains("PubChem CID 2244"))
        #expect(try flags(s).isEmpty)
    }

    @Test func exactIdentifiersAreCaughtOffline() async throws {
        for q in ["58-08-2", "CN1C=NC2=C1C(=O)N(C(=O)N2C)C", caffeineKey.lowercased()] {
            let http = RoutedHTTP([])
            let (ctx, s) = try context(http)
            let out = try await tool().run(["query": .string(q)], ctx)
            #expect(out.isError && out.text.hasPrefix("⚠ CONTROLLED"), "\(q)")
            #expect(http.urls.isEmpty, "an exact hit needs no network")
            #expect(try flags(s).count == 1)
        }
    }

    @Test func unresolvedSmilesFallsBackToLocalCanonicalisation() async throws {
        let smi = "Cn1cnc2c1c(=O)n(C)c(=O)n2C"
        let (ctx, s) = try context(RoutedHTTP([]))
        let out = try await tool(local: { _ in ["SOMEOTHERSALTX-UHFFFAOYSA-N", caffeineKey] }).run(["query": .string(smi)], ctx)
        #expect(out.text.hasPrefix("⚠ CONTROLLED"))
        #expect(try flags(s).first?.data["basis"]?.stringValue == "inchikey")

        let (ctx2, _) = try context(RoutedHTTP([]))
        let clean = try await tool(local: { _ in ["BSYNRYMUTXBXSQ-UHFFFAOYSA-N"] }).run(["query": "CC(=O)Oc1ccccc1C(=O)O"], ctx2)
        #expect(clean.text.contains("screened locally"))
    }

    @Test func unscreenableStructureSaysSo() async throws {
        let (ctx, s) = try context(RoutedHTTP([]))
        let out = try await tool().run(["query": "Cn1cnc2c1c(=O)n(C)c(=O)n2C"], ctx)
        #expect(out.isError)
        #expect(out.text.contains("NOT screened"))
        #expect(try flags(s).isEmpty)
    }

    @Test func bundledListHasStructureKeys() {
        let entries = ChemScreen.bundled.entries
        #expect(entries.count > 100)
        #expect(entries.allSatisfy { $0.inchikey.map(ChemScreen.isInChIKey) ?? false }, "regenerate with scripts/gen-controlled-inchikeys.py")
    }
}
