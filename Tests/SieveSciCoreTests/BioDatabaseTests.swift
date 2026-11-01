import Foundation
import Testing
@testable import SieveSciCore

// Offline: canned responses in the shape the real APIs return (checked by LiveDatabaseTests).

private func run(_ input: JSON, _ routes: [(String, String)], screen: ChemScreen? = nil) async throws -> (ToolOutput, SessionServices, RoutedHTTP) {
    let http = RoutedHTTP(routes)
    let (ctx, s) = try toolContext(http: http)
    var tool = BioDatabaseTool()
    if let screen { tool.screen = screen }
    return (try await tool.run(input, ctx), s, http)
}

@Suite struct BioDatabases {
    @Test func uniprotSearch() async throws {
        let body = #"{"results":[{"primaryAccession":"P04637","uniProtkbId":"P53_HUMAN","entryType":"UniProtKB reviewed (Swiss-Prot)","proteinDescription":{"recommendedName":{"fullName":{"value":"Cellular tumor antigen p53"}}},"genes":[{"geneName":{"value":"TP53"}}],"organism":{"scientificName":"Homo sapiens"},"sequence":{"length":393},"comments":[{"commentType":"FUNCTION","texts":[{"value":"Acts as a tumor suppressor."}]}]}]}"#
        let (out, _, http) = try await run(["database": "uniprot", "query": "TP53 human"], [("rest.uniprot.org/uniprotkb/search", body)])
        #expect(out.text.contains("UniProt P04637 (P53_HUMAN, Swiss-Prot) · Cellular tumor antigen p53"))
        #expect(out.text.contains("gene TP53 · Homo sapiens · 393 aa"))
        #expect(out.text.contains("function: Acts as a tumor suppressor."))
        #expect(http.urls.first?.contains("query=TP53%20human") == true)
    }

    @Test func ncbiSearchThenSummary() async throws {
        let (out, _, http) = try await run(["database": "ncbi", "ncbi_db": "gene", "query": "BRCA1"], [
            ("esearch.fcgi?db=gene", #"{"esearchresult":{"count":"1","idlist":["672"]}}"#),
            ("esummary.fcgi?db=gene&id=672", #"{"result":{"uids":["672"],"672":{"name":"BRCA1","description":"BRCA1 DNA repair associated","organism":{"scientificname":"Homo sapiens"},"summary":"Nuclear phosphoprotein."}}}"#),
        ])
        #expect(out.text.hasPrefix("1 matches; showing 1"))
        #expect(out.text.contains("Gene 672 · BRCA1 — BRCA1 DNA repair associated (Homo sapiens)"))
        #expect(http.urls.count == 2)
    }

    @Test func clinicalTrialsStudy() async throws {
        let body = #"{"protocolSection":{"identificationModule":{"nctId":"NCT04280705","briefTitle":"Adaptive COVID-19 Treatment Trial"},"statusModule":{"overallStatus":"COMPLETED"},"designModule":{"phases":["PHASE3"],"enrollmentInfo":{"count":1062}},"conditionsModule":{"conditions":["COVID-19"]},"armsInterventionsModule":{"interventions":[{"name":"Remdesivir"},{"name":"Placebo"}]},"sponsorCollaboratorsModule":{"leadSponsor":{"name":"NIAID"}}},"hasResults":true}"#
        let (out, _, _) = try await run(["database": "clinicaltrials", "id": "nct04280705"], [("clinicaltrials.gov/api/v2/studies/NCT04280705", body)])
        #expect(out.text.contains("NCT04280705 · Adaptive COVID-19 Treatment Trial"))
        #expect(out.text.contains("COMPLETED · PHASE3 · n=1062 · results posted · NIAID"))
        #expect(out.text.contains("interventions: Remdesivir, Placebo"))
    }

    @Test func chemblMoleculesAreScreened() async throws {
        // Stand-in list (caffeine), never the real controlled-substance list.
        let screen = ChemScreen(entries: [.init(cas: "58-08-2", source: "test list", smiles: "CN1C=NC2=C1C(=O)N(C(=O)N2C)C", inchikey: "RYYVLZVUVIJVGH-UHFFFAOYSA-N")])
        let body = #"{"molecules":[{"molecule_chembl_id":"CHEMBL113","pref_name":"CAFFEINE","max_phase":"4.0","molecule_structures":{"canonical_smiles":"Cn1c(=O)c2c(ncn2C)n(C)c1=O","standard_inchi_key":"RYYVLZVUVIJVGH-UHFFFAOYSA-N"},"molecule_properties":{"full_molformula":"C8H10N4O2","full_mwt":"194.19"}},{"molecule_chembl_id":"CHEMBL25","pref_name":"ASPIRIN","max_phase":"4.0","molecule_structures":{"canonical_smiles":"CC(=O)Oc1ccccc1C(=O)O","standard_inchi_key":"BSYNRYMUTXBXSQ-UHFFFAOYSA-N"},"molecule_properties":{"full_molformula":"C9H8O4","full_mwt":"180.16"}}]}"#
        let (out, s, _) = try await run(["database": "chembl", "query": "xanthine"], [("chembl/api/data/molecule/search.json", body)], screen: screen)
        let lines = out.text.components(separatedBy: "\n")
        #expect(lines.first?.hasPrefix("⚠ CONTROLLED SUBSTANCE") == true, "the flag sits right above the flagged molecule")
        #expect(lines[1].hasPrefix("ChEMBL CHEMBL113"))
        #expect(out.text.components(separatedBy: "CONTROLLED").count == 2, "aspirin is not flagged")
        #expect(try AuditLog.read(s.audit.url).filter { $0.kind == "chem_safety_flag" }.count == 1)
    }

    @Test func rateLimitIsRetried() async throws {
        let http = RoutedHTTP(sequenced: [("alphafold.ebi.ac.uk/api/prediction/P04637", [
            (429, #"{"error":"rate limited"}"#),
            (200, #"[{"entryId":"AF-P04637-F1","uniprotDescription":"Cellular tumor antigen p53","organismScientificName":"Homo sapiens","latestVersion":6,"globalMetricValue":75.1,"pdbUrl":"https://alphafold.ebi.ac.uk/files/AF-P04637-F1-model_v6.pdb"}]"#),
        ])])
        let (ctx, _) = try toolContext(http: http)
        let out = try await BioDatabaseTool().run(["database": "alphafold", "id": "P04637"], ctx)
        #expect(!out.isError)
        #expect(out.text.contains("model v6 · mean pLDDT 75.1"))
        #expect(http.urls.count == 2)
    }

    @Test func outageIsReportedNotGuessed() async throws {
        let http = RoutedHTTP(sequenced: [("rest.ensembl.org", [(503, "unavailable")])])
        let (ctx, _) = try toolContext(http: http)
        let out = try await BioDatabaseTool().run(["database": "ensembl", "query": "BRCA2"], ctx)
        #expect(out.isError)
        #expect(out.text.contains("unavailable right now (HTTP 503"))
        #expect(http.urls.count == 3, "two retries, then give up")
    }

    @Test func needsQueryOrId() async throws {
        let (out, _, http) = try await run(["database": "pdb"], [])
        #expect(out.isError)
        #expect(http.urls.isEmpty)
    }
}
