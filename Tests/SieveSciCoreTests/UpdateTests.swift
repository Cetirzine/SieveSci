import Foundation
import Testing
@testable import SieveSciCore

@Suite struct UpdateChecks {
    @Test func versionsCompareNumerically() {
        #expect(Updates.isNewer("0.2.0", than: "0.1.0"))
        #expect(Updates.isNewer("v0.10.0", than: "0.9.9"))
        #expect(Updates.isNewer("1.0", than: "0.99.99"))
        #expect(!Updates.isNewer("0.1.0", than: "0.1.0"))
        #expect(!Updates.isNewer("0.1.0", than: "0.2.0"))
        #expect(!Updates.isNewer("0.2.0-beta.1", than: "0.2.0"))
        #expect(Updates.isNewer("0.2.0", than: "0.2.0-beta.1"))
    }

    @Test func parsesGitHubReleaseAndPrefersDiskImage() throws {
        let json = """
        {"tag_name":"v0.2.0","name":"SieveSci 0.2.0","body":"notes","html_url":"https://github.com/Cetirzine/SieveSci/releases/tag/v0.2.0",
         "assets":[
          {"name":"SieveSci-0.2.0.zip","size":10,"digest":"sha256:AA","browser_download_url":"https://example.com/a.zip"},
          {"name":"SieveSci-0.2.0.dmg","size":20,"digest":"sha256:BB","browser_download_url":"https://example.com/a.dmg"},
          {"name":"notes.txt","size":1,"browser_download_url":"https://example.com/n.txt"}]}
        """
        let r = try Updates.parse(Data(json.utf8))
        #expect(r.version == "0.2.0")
        #expect(r.asset?.name == "SieveSci-0.2.0.dmg")
        #expect(r.asset?.sha256 == "bb")
        #expect(r.asset?.size == 20)
    }

    @Test func releaseWithoutAppAssetHasNone() throws {
        let json = #"{"tag_name":"v0.3.0","html_url":"https://github.com/x/y","assets":[{"name":"source.tar.gz","size":1,"browser_download_url":"https://e.com/s"}]}"#
        #expect(try Updates.parse(Data(json.utf8)).asset == nil)
        #expect(throws: (any Error).self) { try Updates.parse(Data("{}".utf8)) }
    }

    @Test func verifyChecksSizeAndDigest() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("upd-\(UUID().uuidString)")
        try Data("hello".utf8).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        let digest = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        #expect(try Updates.sha256(of: f) == digest)
        let good = AppRelease.Asset(name: "SieveSci.dmg", url: f, size: 5, sha256: digest)
        try Updates.verify(f, against: good)
        let wrongSize = AppRelease.Asset(name: "SieveSci.dmg", url: f, size: 6, sha256: digest)
        #expect(throws: (any Error).self) { try Updates.verify(f, against: wrongSize) }
        let wrongHash = AppRelease.Asset(name: "SieveSci.dmg", url: f, size: 5, sha256: String(repeating: "0", count: 64))
        #expect(throws: (any Error).self) { try Updates.verify(f, against: wrongHash) }
    }
}
