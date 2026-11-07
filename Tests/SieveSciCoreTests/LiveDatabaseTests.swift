import Foundation
import Testing
@testable import SieveSciCore

/// Hits the real public APIs, to catch response-format changes the offline fixtures cannot.
/// Off by default: `SIEVESCI_LIVE=1 swift test --filter LiveDatabases`.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["SIEVESCI_LIVE"] == "1"))
struct LiveDatabases {
    static let probes: [(String, JSON)] = [
        ("uniprot search", ["database": "uniprot", "query": "gene:TP53 AND organism_id:9606 AND reviewed:true", "limit": 2]),
        ("uniprot id", ["database": "uniprot", "id": "P04637"]),
        ("ncbi gene", ["database": "ncbi", "ncbi_db": "gene", "query": "BRCA1[sym] AND human[orgn]", "limit": 2]),
        ("ncbi pubmed", ["database": "ncbi", "ncbi_db": "pubmed", "query": "CRISPR base editing", "limit": 2]),
        ("ncbi gds", ["database": "ncbi", "ncbi_db": "gds", "query": "single cell liver", "limit": 2]),
        ("ncbi sra", ["database": "ncbi", "ncbi_db": "sra", "query": "SARS-CoV-2 nanopore", "limit": 2]),
        ("pdb search", ["database": "pdb", "query": "hemoglobin", "limit": 2]),
        ("pdb id", ["database": "pdb", "id": "4HHB"]),
        ("alphafold", ["database": "alphafold", "id": "P04637"]),
        ("ensembl symbol", ["database": "ensembl", "query": "BRCA2"]),
        ("ensembl id", ["database": "ensembl", "id": "ENSG00000139618"]),
        ("chembl molecule", ["database": "chembl", "query": "imatinib", "limit": 2]),
        ("chembl target", ["database": "chembl", "kind": "target", "query": "EGFR", "limit": 2]),
        ("reactome search", ["database": "reactome", "query": "apoptosis", "limit": 3]),
        ("reactome uniprot", ["database": "reactome", "query": "P04637", "limit": 3]),
        ("reactome id", ["database": "reactome", "id": "R-HSA-109581"]),
        ("trials search", ["database": "clinicaltrials", "query": "glioblastoma vaccine", "limit": 2]),
        ("trials id", ["database": "clinicaltrials", "id": "NCT04280705"]),
    ]

    @Test(arguments: probes.map(\.0)) func probe(_ label: String) async throws {
        let input = try #require(Self.probes.first { $0.0 == label }?.1)
        let (s, ws) = try makeServices()
        let ctx = ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let out = try await BioDatabaseTool().run(input, ctx)
        print("── \(label)\n\(out.text)\n")
        #expect(!out.isError, "\(label): \(out.text)")
        #expect(!out.text.contains(" · ?"), "\(label): a field did not parse")
        // Every record links to its page, so replies can link what they cite.
        #expect(out.text.contains("https://"), "\(label): no record link")
    }

    @Test func citationGraph() async throws {
        let (s, ws) = try makeServices()
        let ctx = ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let out = try await PaperGraphTool().run(["ref": "10.1038/nature14539", "limit": 3], ctx)
        print("── paper_graph\n\(out.text)\n")
        #expect(!out.isError && out.text.contains("References (most-cited first):") && out.text.contains("Cited by"))
        let lit = try await LiteratureSearchTool().run(["query": "deep learning review", "source": "openalex", "limit": 2], ctx)
        #expect(lit.text.contains("cited "), "OpenAlex results show citation counts")
    }

    /// A real environment (system uv or venv + pip, real PyPI), built in a temp directory.
    @Test func realSkillEnvironment() async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-live-" + UUID().uuidString)
        let dir = ws.appendingPathComponent(".sievesci/skills/tiny")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "---\nname: tiny\ndescription: Live test skill.\ncompatibility: Requires Python 3.9+ and six (pip install six).\n---\nBody.\n"
            .writeReliably(to: dir.appendingPathComponent("SKILL.md"))
        let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (ScriptedProvider(replies: []), "m")), secrets: EnvironmentSecretStore())
        s.environments = SkillEnvironments(root: ws.appendingPathComponent("envs"))
        let ctx = ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
        let setup = try await SkillEnvTool().run(["name": "tiny", "action": "setup"], ctx)
        print("── skill_env setup\n\(setup.text)\n")
        #expect(!setup.isError)
        let py = try await PythonTool().run(["code": "import six, sys; print(six.__version__, sys.prefix)", "env": "tiny"], ctx)
        print("── python in env\n\(py.text)\n")
        #expect(!py.isError && py.text.contains(ws.appendingPathComponent("envs").lastPathComponent))
        s.kernel.shutdownAll()
    }
}

