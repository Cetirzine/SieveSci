import Foundation
import Testing
@testable import SieveSciCore

private func parse(_ compatibility: String, meta extra: [String: Any] = [:], dir: URL? = nil) -> SkillRequirements {
    var meta: [String: Any] = ["compatibility": compatibility]
    for (k, v) in extra { meta[k] = v }
    return SkillRequirementsParser.parse(meta: meta, body: "", dir: dir)
}

// Compatibility lines as K-Dense's drug-discovery skills (MIT) write them.
@Suite struct SkillRequirementParsing {
    @Test func versionRangesAndPackages() {
        let boltz = parse("The bundled scripts need only Python 3.10+ and the standard library. Running a prediction needs boltz 2.2+ (pip install boltz, Python >=3.10 and <3.13) and an NVIDIA GPU; 24 GB is a practical minimum for a typical protein-ligand complex, CPU works but is 50-100x slower.")
        #expect(boltz.python.spec == ">=3.10,<3.13")
        #expect(boltz.packages == ["boltz>=2.2"], "the stated minimum version is kept")
        #expect(boltz.gpu == .recommended, "CPU works, slowly")

        let admet = parse("Requires Python 3.10+. Generating predictions needs admet-ai 2.0+ (pip, requires-python >=3.11, MIT) plus chemprop and RDKit; models download on first use. CPU is adequate for thousands of molecules.")
        #expect(admet.python.spec == ">=3.11", "the stricter of the two constraints")
        #expect(admet.packages == ["admet-ai>=2.0"])
        #expect(admet.gpu == .none)

        #expect(parse("Requires Python 3.9–3.10 (molfeat 0.11.0 declares `requires-python <3.11`).").python.spec == ">=3.9,<3.11")
        #expect(parse("Requires Python 3.7–3.11 (PyPI 2.8.0 caps at <3.12).").python.spec == ">=3.7,<3.12")
        let tdc = parse("Requires uv, CPython 3.11, PyTDC 1.1.15, and setuptools 80.9.0 for its legacy pkg_resources runtime import.")
        #expect(tdc.python.spec == ">=3.11,<3.12")
        #expect(tdc.packages == ["pytdc==1.1.15", "setuptools==80.9.0"])
        #expect(parse("Requires Python 3.8+ and datamol (uv pip install).").packages == ["datamol"])
        #expect(parse("Requires Python 3.10+ with pandas, numpy, scipy and requests. Analysis is download-based.").packages == ["pandas", "numpy", "scipy", "requests"])
        #expect(parse("Requires Python 3.11+ with openmm and mdanalysis, best installed from conda-forge.").packages == ["openmm", "mdanalysis"])
        #expect(parse("Running a docking calculation additionally needs the AutoDock Vina binary (conda install -c conda-forge vina, or pip install vina 1.2.7) and Meeko 0.7+ (pip install meeko) on PATH.").packages == ["vina==1.2.7", "meeko"])
    }

    @Test func warnsAboutTheWrongPackage() {
        let fep = parse("Running a calculation needs openfe 1.12+ installed from conda-forge, docker, or singularity — note that `pip install openfe` fetches an unrelated 0.0.12 placeholder. An NVIDIA GPU is effectively mandatory — a single edge is hours of MD.")
        #expect(fep.packages.isEmpty, "the placeholder package is never installed")
        #expect(fep.manual.contains { $0.contains("wrong package") })
        #expect(fep.gpu == .required)
    }

    @Test func keysBinariesAndCost() {
        let esm = parse("Requires Python >=3.12,<3.13 and `esm` 3.2.3 from PyPI. Local ESM3-open inference needs a GPU with roughly 16 GB of memory and a gated Hugging Face licence acceptance; hosted inference through Forge or Biohub needs an API key in ESM_API_KEY and no local GPU.")
        #expect(esm.python.spec == ">=3.12,<3.13")
        #expect(esm.packages == ["esm==3.2.3"])
        #expect(esm.envVars == ["ESM_API_KEY"])
        #expect(esm.gpu == .recommended, "a GPU, or the hosted API instead")
        let ab = parse("number_antibody.py additionally needs anarci (pip install anarci) and HMMER with hmmscan on PATH (conda install -c bioconda hmmer, or brew install hmmer). No GPU, no network, no API key.")
        #expect(ab.binaries == ["hmmscan"])
        #expect(ab.gpu == .none && !ab.unnamedKey)
        #expect(ab.manual.contains("conda: hmmer"))
        let rowan = parse("Requires Python 3.12+ and a ROWAN_API_KEY. Rowan is a commercial hosted service — compute is metered and billed, so a large batch has a real cost.")
        #expect(rowan.metered && rowan.envVars == ["ROWAN_API_KEY"])
        #expect(parse("Requires Python 3.10+, a Tamarind Bio account, and an API key from app.tamarind.bio.").unnamedKey)
        #expect(!parse("Requires Python 3.10+. The bundled scripts use only the Python standard library and need no API key or account.").unnamedKey)
        #expect(!parse("Requires Python 3.10+ only.").needsEnvironment, "standard-library skills need no environment")
    }

    @Test func explicitDeclarationsWin() throws {
        let explicit = parse("Requires Python 3.10+ with pandas.", meta: ["metadata": ["sievesci": ["python": ">=3.11,<3.13", "packages": ["scanpy==1.10.2"], "gpu": "required", "env": ["X_TOKEN"]]]])
        #expect(explicit.python.spec == ">=3.11,<3.13" && explicit.packages == ["scanpy==1.10.2"] && explicit.gpu == .required && explicit.envVars == ["X_TOKEN"])
        #expect(explicit.source == "front matter")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-req-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "# pinned\nnumpy==2.1.0\n\npandas>=2  # data frames\n-r other.txt\n".write(to: dir.appendingPathComponent("requirements.txt"), atomically: true, encoding: .utf8)
        let req = parse("Requires Python 3.10+ with scipy.", dir: dir)
        #expect(req.packages == ["numpy==2.1.0", "pandas>=2"] && req.source == "requirements.txt")
        #expect(req.fingerprint != parse("Requires Python 3.10+ with scipy.").fingerprint)
    }
}

/// Records installer commands; `venv` creates a bin/python that marks itself, then runs the real python3.
final class FakeInstaller: EnvironmentInstaller, @unchecked Sendable {
    private let lock = NSLock()
    let tools: [String: String]
    let minors: [String: Int]
    var failPip = false
    private(set) var commands: [[String]] = []

    init(tools: [String: String], minors: [String: Int] = [:]) { self.tools = tools; self.minors = minors }

    func which(_ name: String) -> String? { tools[name] }

    func run(_ exe: String, _ args: [String]) async throws -> ProcessResult {
        lock.withLock { commands.append([exe] + args) }
        func ok(_ out: String = "") -> ProcessResult { ProcessResult(exitCode: 0, stdout: out, stderr: "", timedOut: false, duration: 0) }
        if args.first == "-c" { return minors[exe].map { ok("3 \($0)\n") } ?? ProcessResult(exitCode: 1, stdout: "", stderr: "no", timedOut: false, duration: 0) }
        if let i = args.firstIndex(of: "venv") {
            let dir = URL(fileURLWithPath: args.last!)
            precondition(i < args.count - 1)
            let bin = dir.appendingPathComponent("bin")
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            let py = bin.appendingPathComponent("python")
            try "#!/bin/sh\nexport SIEVESCI_FAKE_ENV=\(dir.lastPathComponent)\nexec /usr/bin/env python3 \"$@\"\n".write(to: py, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: py.path)
            return ok()
        }
        if args.contains("install") && failPip { return ProcessResult(exitCode: 1, stdout: "", stderr: "ERROR: No matching distribution", timedOut: false, duration: 0) }
        return ok("Installed")
    }
}

@Suite struct SkillEnvironmentManagement {
    static let skillText = """
    ---
    name: demo
    description: Demo analysis skill.
    compatibility: Requires Python >=3.10 and <3.13 with pandas and requests. Needs DEMO_SIEVESCI_API_KEY. Fitting needs an NVIDIA GPU.
    ---
    Run scripts/fit.py.
    """

    func services(installer: FakeInstaller) throws -> (SessionServices, URL) {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-test-" + UUID().uuidString)
        let dir = ws.appendingPathComponent(".sievesci/skills/demo")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.skillText.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let s = try SessionServices(taskId: "t1", workspace: ws, models: RoleModels(main: (ScriptedProvider(replies: []), "m")), secrets: EnvironmentSecretStore())
        s.environments = SkillEnvironments(root: ws.appendingPathComponent("envs"), installer: installer)
        return (s, ws)
    }

    func ctx(_ s: SessionServices, _ ws: URL) -> ToolContext {
        ToolContext(workspace: ws, sessionId: "main", role: .main, ledger: s.ledger, audit: s.audit, services: s)
    }

    @Test(.disabled(if: Platform.isWindows, "the fake venv interpreter is a shell script")) func setupWithUvThenRunPythonAndBashInIt() async throws {
        let fake = FakeInstaller(tools: ["uv": "/opt/uv"])
        let (s, ws) = try services(installer: fake)
        let c = ctx(s, ws)

        let shown = try await SkillTool().run(["name": "demo"], c).text
        #expect(shown.contains("<environment skill=\"demo\""))
        #expect(shown.contains("Environment not set up"))
        #expect(shown.contains("needs an NVIDIA GPU"))
        #expect(shown.contains("DEMO_SIEVESCI_API_KEY"))

        let early = try await PythonTool().run(["code": "print(1)", "env": "demo"], c)
        #expect(early.isError && early.text.contains("not set up"))

        #expect(SkillEnvTool().effect(for: ["name": "demo", "action": "setup"]) == .external)
        #expect(SkillEnvTool().effect(for: ["name": "demo"]) == .readOnly)
        let setup = try await SkillEnvTool().run(["name": "demo", "action": "setup"], c)
        #expect(!setup.isError, "\(setup.text)")
        #expect(fake.commands.contains { $0 == ["/opt/uv", "venv", "--python", ">=3.10,<3.13", $0.last!] })
        #expect(fake.commands.contains { $0.starts(with: ["/opt/uv", "pip", "install", "--python"]) && $0.suffix(2) == ["pandas", "requests"] })
        #expect(try AuditLog.read(s.audit.url).contains { $0.kind == "skill_env_setup" })

        let again = try await SkillEnvTool().run(["name": "demo", "action": "setup"], c)
        #expect(again.text.contains("already present"))

        let py = try await PythonTool().run(["code": "import os; print(os.environ.get('SIEVESCI_FAKE_ENV'))", "env": "demo"], c)
        #expect(py.text.hasPrefix("demo-"), "ran with the environment's interpreter: \(py.text)")
        let plain = try await PythonTool().run(["code": "import os; print(os.environ.get('SIEVESCI_FAKE_ENV'))"], c)
        #expect(plain.text.hasPrefix("None"), "the default kernel is untouched")

        let sh = try await BashTool().run(["command": "echo \"$VIRTUAL_ENV\"; command -v python", "env": "demo"], c)
        let envDir = s.environments.root.path
        #expect(sh.text.components(separatedBy: "\n").prefix(2).allSatisfy { $0.contains(envDir) }, "\(sh.text)")
        s.kernel.shutdownAll()
    }

    @Test(.disabled(if: Platform.isWindows, "the fake venv interpreter is a shell script")) func withoutUvPicksTheNewestSystemPythonInRange() async throws {
        let fake = FakeInstaller(tools: ["python3.13": "/usr/bin/py313", "python3.12": "/usr/bin/py312", "python3.9": "/usr/bin/py39", "python3": "/usr/bin/py313"],
                                 minors: ["/usr/bin/py313": 13, "/usr/bin/py312": 12, "/usr/bin/py39": 9])
        let (s, ws) = try services(installer: fake)
        let out = try await SkillEnvTool().run(["name": "demo", "action": "setup"], ctx(s, ws))
        #expect(!out.isError, "\(out.text)")
        #expect(fake.commands.contains { $0.first == "/usr/bin/py312" && $0.dropFirst().starts(with: ["-m", "venv"]) }, "3.13 is out of range")
        #expect(fake.commands.contains { $0.last == "requests" && $0.contains("pip") })
    }

    @Test func failuresAreReportedAndLeaveNoHalfBuiltEnvironment() async throws {
        let none = FakeInstaller(tools: ["python3": "/usr/bin/py39"], minors: ["/usr/bin/py39": 9])
        let (s, ws) = try services(installer: none)
        let out = try await SkillEnvTool().run(["name": "demo", "action": "setup"], ctx(s, ws))
        #expect(out.isError && out.text.contains("brew install uv"))

        let broken = FakeInstaller(tools: ["uv": "/opt/uv"])
        broken.failPip = true
        let (s2, ws2) = try services(installer: broken)
        let out2 = try await SkillEnvTool().run(["name": "demo", "action": "setup"], ctx(s2, ws2))
        #expect(out2.isError && out2.text.contains("No matching distribution"))
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: s2.environments.root.path)) ?? []).isEmpty)
        #expect(try await PythonTool().run(["code": "print(1)", "env": "demo"], ctx(s2, ws2)).isError)
    }

    @Test func subagentsAreAskedBeforeDownloading() async throws {
        let (s, _) = try services(installer: FakeInstaller(tools: ["uv": "/opt/uv"]))
        s.sandboxMode = .workspaceWrite
        let asked = LockedBox<[String]>([])
        s.requestPermission = { req in asked.mutate { $0.append(req.summary) }; return .deny("") }
        let w = s.makeSubagent(role: .worker, purpose: "docking")
        let use = ToolUse(id: "u1", name: "skill_env", input: ["name": "demo", "action": "setup"])
        #expect(await w.authorize(SkillEnvTool(), use, SkillEnvTool().effect(for: use.input)) != nil)
        #expect(asked.value.count == 1)
        #expect(asked.value.first?.contains("Python environment for skill demo") == true, "\(asked.value)")
    }

    @Test func activationQuotesPaths() {
        let a = SkillEnvironments.activation(python: "/tmp/it's here/env/bin/python")
        #expect(a.contains("export VIRTUAL_ENV='/tmp/it'\\''s here/env'"))
        #expect(a.contains("export PATH='/tmp/it'\\''s here/env/bin':\"$PATH\""))
    }
}
