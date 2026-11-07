import Foundation
import Testing
@testable import SieveSciCore

/// Child processes (CLI installers, agents, pip) get the computer's proxy when the app has none.
@Suite struct SystemProxyTests {
    @Test func macSettingsBecomeCurlVariables() {
        let s = SystemProxy.Settings(http: "127.0.0.1:7877", https: "127.0.0.1:7877", socks: "127.0.0.1:7877",
                                     exceptions: ["*zhihu.com", "localhost", "*.local", "127.*", "10.*", "192.168.*", "172.2*"])
        let env = SystemProxy.environment(s)
        #expect(env["https_proxy"] == "http://127.0.0.1:7877" && env["HTTPS_PROXY"] == "http://127.0.0.1:7877")
        #expect(env["http_proxy"] == "http://127.0.0.1:7877")
        #expect(env["all_proxy"] == nil, "socks only when there is no HTTP proxy")
        let bypass = (env["no_proxy"] ?? "").split(separator: ",").map(String.init)
        #expect(bypass.contains("zhihu.com") && bypass.contains("local") && bypass.contains("localhost"))
        #expect(bypass.contains("127.0.0.0/8") && bypass.contains("10.0.0.0/8") && bypass.contains("192.168.0.0/16"))
        #expect(!bypass.contains { $0.contains("*") })
    }

    @Test func socksOnly() {
        let env = SystemProxy.environment(.init(http: nil, https: nil, socks: "127.0.0.1:1080"))
        #expect(env["all_proxy"] == "socks5h://127.0.0.1:1080" && env["https_proxy"] == nil)
        #expect(SystemProxy.environment(.init()).isEmpty)
    }

    @Test func windowsProxyServerForms() {
        let one = SystemProxy.parseWindows(server: "127.0.0.1:7890", override: "localhost;127.*;<local>")
        #expect(one?.http == "127.0.0.1:7890" && one?.https == "127.0.0.1:7890")
        #expect(SystemProxy.noProxy(one?.exceptions ?? []) == ["localhost", "127.0.0.1", "::1", "127.0.0.0/8"])
        let per = SystemProxy.parseWindows(server: "http=h:1;https=h:2;socks=h:3", override: "")
        #expect(per?.http == "h:1" && per?.https == "h:2" && per?.socks == "h:3")
        #expect(SystemProxy.parseWindows(server: "", override: "") == nil)
    }

    @Test func anExportedProxyWins() {
        #expect(SystemProxy.hasProxy(["HTTPS_PROXY": "http://x:1"]))
        #expect(!SystemProxy.hasProxy(["PATH": "/bin", "https_proxy": ""]))
    }
}
