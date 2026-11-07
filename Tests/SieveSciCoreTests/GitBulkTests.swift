import Foundation
import Testing
@testable import SieveSciCore

/// A workspace holding generated data keeps a history of everything else.
@Suite struct GitBulkData {
    @Test func bulkFoldersAreFoundAtTheRightDepth() {
        var paths = ["scripts/run.py", "report.md", "benchmark/summary.json", "benchmark/s4_index/a.tsv"]
        for i in 0..<3_000 { paths.append("benchmark/fpocket/p\(i)/out.pdb") }            // spread thin
        for i in 0..<2_500 { paths.append("benchmark/afdb/AF-\(i).cif") }                  // one flat folder
        for i in 0..<50 { paths.append("benchmark/foldseek/q\(i).m8") }                     // small: kept
        let bulk = GitHistory.bulkDirectories(paths, budget: 2_000)
        #expect(Set(bulk.map(\.dir)) == ["benchmark/fpocket/", "benchmark/afdb/"])
        #expect(bulk.first { $0.dir == "benchmark/fpocket/" }?.files == 3_000)
        #expect(GitHistory.bulkDirectories(Array(paths.prefix(100)), budget: 2_000).isEmpty)
    }

    @Test func aWorkspaceWithGeneratedDataIsStillVersioned() async throws {
        guard ProcessRunner.which("git") != nil else { return }
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("bulk-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: ws.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try "print(1)".write(to: ws.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8)
        let gen = ws.appendingPathComponent("out/pockets")
        try fm.createDirectory(at: gen, withIntermediateDirectories: true)
        for i in 0..<120 { try "x".write(to: gen.appendingPathComponent("p\(i).txt"), atomically: true, encoding: .utf8) }
        let g = GitHistory(workspace: ws)
        g.bulkDirFiles = 100
        g.maxSnapshotFiles = 50   // the whole folder would have been refused before
        await g.prepare()
        let c = await g.snapshot(subject: "baseline", trailers: [:])
        #expect(c != nil && g.skippedReason == nil)
        #expect(g.newlyExcluded.map(\.dir) == ["out/pockets/"])
        let tracked = await g.git(["ls-files"])?.stdout ?? ""
        #expect(tracked.contains("scripts/run.py") && !tracked.contains("out/pockets"))
        let exclude = try String(contentsOf: g.gitDir.appendingPathComponent("info/exclude"), encoding: .utf8)
        #expect(exclude.contains("/out/pockets/"))
        // Next time the folder is not even listed, and nothing is announced again.
        try "print(2)".write(to: ws.appendingPathComponent("scripts/run.py"), atomically: true, encoding: .utf8)
        _ = await g.snapshot(subject: "turn", trailers: [:])
        #expect(g.newlyExcluded.isEmpty)
    }

    /// Dry run on a real file list: SIEVESCI_BULK_LIST=<file of NUL-separated paths>.
    @Test func dryRunOnARealWorkspace() throws {
        guard let f = ProcessInfo.processInfo.environment["SIEVESCI_BULK_LIST"] else { return }
        let paths = try String(contentsOfFile: f, encoding: .utf8).split(separator: "\0").map(String.init)
        let started = Date()
        let bulk = GitHistory.bulkDirectories(paths, budget: 2_000)
        let left = paths.filter { p in !bulk.contains { p.hasPrefix($0.dir) } }
        print("DRYRUN \(paths.count) files → excluded \(bulk.count) folders, \(left.count) files left, \(String(format: "%.1f", Date().timeIntervalSince(started))) s")
        for b in bulk { print("DRYRUN   \(b.dir) \(b.files)") }
        for p in Set(left.map { $0.split(separator: "/").prefix(2).joined(separator: "/") }).sorted().prefix(40) { print("DRYRUN kept \(p)") }
    }
}

@Suite struct DroppedConnections {
    @Test func libcurlsEmptyReplyIsRetried() {
        let e = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSLocalizedDescriptionKey: "Empty reply from server"])
        #expect(StreamWatch.isDropped(e))
        #expect(StreamWatch.isDropped(NSError(domain: "x", code: 52, userInfo: [NSLocalizedDescriptionKey: "Empty reply from server"])))
        #expect(StreamWatch.isDropped(URLError(.networkConnectionLost)))
        #expect(!StreamWatch.isDropped(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(!StreamWatch.isDropped(ProviderError.http(status: 400, body: "bad request")))
    }
}

@Suite struct WindowsPaths {
    @Test func extendedAndURLFormsBecomePlainPaths() {
        #expect(Platform.windowsPath(#"\\?\C:\Users\Yue_H\AppData\Local\SieveSci\engine\sievesci.exe"#) == #"C:\Users\Yue_H\AppData\Local\SieveSci\engine\sievesci.exe"#)
        #expect(Platform.windowsPath("/?/C:/Users/Yue_H/AppData/Local/SieveSci/engine") == #"C:\Users\Yue_H\AppData\Local\SieveSci\engine"#)
        #expect(Platform.windowsPath("/C:/tools/x.exe") == #"C:\tools\x.exe"#)
        #expect(Platform.windowsPath(#"D:\data"#) == #"D:\data"#)
    }
}

@Suite struct WindowsEnvironment {
    @Test func registryPathEntriesExpand() {
        let env = ["USERPROFILE": #"C:\Users\Yue_H"#, "LocalAppData": #"C:\Users\Yue_H\AppData\Local"#]
        #expect(Platform.expandEnvironment(#"%USERPROFILE%\.local\bin"#, env: env) == #"C:\Users\Yue_H\.local\bin"#)
        #expect(Platform.expandEnvironment(#"%LOCALAPPDATA%\agy\bin"#, env: env) == #"C:\Users\Yue_H\AppData\Local\agy\bin"#)
        #expect(Platform.expandEnvironment("%NOPE%\\x", env: env) == "%NOPE%\\x")
    }

    @Test func aSilentLeaderboardDoesNotHoldTheRefresh() async throws {
        let started = Date()
        await #expect(throws: TimeLimitExceeded.self) {
            try await withTimeLimit(0.3) { try await Task.sleep(nanoseconds: 5_000_000_000); return 1 }
        }
        #expect(Date().timeIntervalSince(started) < 2)
    }
}
