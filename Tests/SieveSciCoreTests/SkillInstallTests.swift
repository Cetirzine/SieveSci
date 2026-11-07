import Foundation
import Testing
@testable import SieveSciCore

/// Skills install from where people share them: GitHub links, git URLs and .zip archives.
@Suite struct SkillInstall {
    @Test func gitHubLinksAreUnderstood() {
        #expect(SkillInstaller.gitSource("https://github.com/acme/skills") == .init(repo: "https://github.com/acme/skills.git", ref: nil, path: ""))
        #expect(SkillInstaller.gitSource("https://github.com/acme/skills/tree/main/bio/pdb-tools") == .init(repo: "https://github.com/acme/skills.git", ref: "main", path: "bio/pdb-tools"))
        #expect(SkillInstaller.gitSource("https://github.com/acme/skills/blob/v2/bio/pdb-tools/SKILL.md") == .init(repo: "https://github.com/acme/skills.git", ref: "v2", path: "bio/pdb-tools"))
        #expect(SkillInstaller.gitSource("git@gitlab.com:lab/skills.git")?.repo == "git@gitlab.com:lab/skills.git")
        #expect(SkillInstaller.gitSource("/tmp/skills.zip") == nil)
    }

    func archive() throws -> (zip: URL, workspace: URL) {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("skill-install-" + UUID().uuidString)
        let src = base.appendingPathComponent("pack/skills")
        for (name, front) in [("pdb-fetch", "name: pdb-fetch\ndescription: Fetch structures from RCSB."), ("broken", "name: broken")] {
            let d = src.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            try "---\n\(front)\n---\nSteps.\n".writeReliably(to: d.appendingPathComponent("SKILL.md"))
            try "print('ok')\n".writeReliably(to: d.appendingPathComponent("run.py"))
        }
        let zip = base.appendingPathComponent("pack.zip")
        #if os(macOS)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", base.appendingPathComponent("pack").path, zip.path]
        try p.run(); p.waitUntilExit()
        #endif
        let ws = base.appendingPathComponent("ws")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        return (zip, ws)
    }

    #if os(macOS)
    @Test func aZipInstallsItsValidSkillsOnce() async throws {
        let (zip, ws) = try archive()
        let r = try await SkillInstaller.install(zip.path, scope: .workspace, workspace: ws, replace: false)
        #expect(r.installed == ["pdb-fetch"])
        #expect(r.refused.contains { $0.hasPrefix("broken") }, "a SKILL.md without a description is refused")
        let dir = ws.appendingPathComponent(".sievesci/skills/pdb-fetch")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("run.py").path))
        #expect(SkillRegistry(workspace: ws).skill("pdb-fetch") != nil, "the registry finds it")
        // Installed already: kept unless replace.
        let again = try await SkillInstaller.install(zip.path, scope: .workspace, workspace: ws, replace: false)
        #expect(again.installed.isEmpty && again.skipped.first?.hasPrefix("pdb-fetch") == true)
        let replaced = try await SkillInstaller.install(zip.path, scope: .workspace, workspace: ws, replace: true)
        #expect(replaced.installed == ["pdb-fetch"])
    }
    #endif

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SIEVESCI_LIVE"] == "1"))
    func aGitHubFolderInstalls() async throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("skill-live-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let r = try await SkillInstaller.install("https://github.com/anthropics/skills/tree/main/skills/pdf", scope: .workspace, workspace: ws, replace: false)
        print("live install:", r.installed, r.skipped, r.refused)
        #expect(r.installed == ["pdf"])
    }
}
