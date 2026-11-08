import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import SieveSciCore

/// The curl path that carries a request when URLSession on Windows sends headers but never the body.
@Suite("CurlTransport", .serialized)
struct CurlTransportTests {
    private func request(_ port: UInt16, path: String = "/v1/chat/completions", body: Data) -> URLRequest {
        URLRequest.json(url: URL(string: "http://127.0.0.1:\(port)\(path)")!, body: body,
                        headers: ["authorization": "Bearer sk-test \"quoted\" \\ back"])
    }

    @Test func streamsServerSentEventsAndSendsTheWholeBody() async throws {
        guard CurlTransport.executable != nil else { return }
        let seen = LockedValue<HTTPRequest?>(nil)
        let server = try #require(LoopbackHTTPServer { r in
            seen.mutate { $0 = r }
            return ("200 OK", Data("data: {\"n\":1}\n\ndata: {\"n\":2}\n\ndata: [DONE]\n\n".utf8))
        })
        // Large enough that libcurl would normally ask "Expect: 100-continue" first.
        let body = Data(("{\"messages\":\"" + String(repeating: "x", count: 1_500_000) + "\"}").utf8)
        let r = try await CurlTransport.postSSE(request(server.port, body: body))
        #expect(r.status == 200)
        var data: [String] = []
        for try await ev in r.events { data.append(ev.data) }
        #expect(data == ["{\"n\":1}", "{\"n\":2}", "[DONE]"])
        let got = try #require(seen.value)
        #expect(got.method == "POST")
        #expect(got.body == body)
        #expect(got.headers["authorization"] == "Bearer sk-test \"quoted\" \\ back")
        #expect(got.headers["expect"] == nil)
        #expect(got.headers["content-type"] == "application/json")
    }

    @Test func anHTTPErrorIsAProviderError() async throws {
        guard CurlTransport.executable != nil else { return }
        let server = try #require(LoopbackHTTPServer { _ in ("429 Too Many Requests", Data("{\"error\":\"slow down\"}".utf8)) })
        do {
            _ = try await CurlTransport.postSSE(request(server.port, body: Data("{}".utf8)))
            Issue.record("expected an error")
        } catch let ProviderError.http(status, body) {
            #expect(status == 429)
            #expect(body.contains("slow down"))
        }
        let (status, data) = try await CurlTransport.send(request(server.port, body: Data("{}".utf8)))
        #expect(status == 429)
        #expect(String(decoding: data, as: UTF8.self).contains("slow down"))
    }

    @Test func noServerIsATransportError() async throws {
        guard CurlTransport.executable != nil else { return }
        // A port that was just free: nothing listens on it.
        let port: UInt16 = try {
            let s = try #require(LoopbackHTTPServer { _ in ("200 OK", Data()) })
            return s.port &+ 7
        }()
        do {
            _ = try await CurlTransport.postSSE(request(port, body: Data("{}".utf8)))
            Issue.record("expected an error")
        } catch {
            #expect(StreamWatch.isTransport(error))
            #expect(!(error is ProviderError))
        }
    }

    @Test func takesOverOnlyNetworkFailuresOfRequestsWithABody() {
        guard CurlTransport.executable != nil else { return }
        let withBody = URLRequest.json(url: URL(string: "https://api.example.com/v1")!, body: Data("{}".utf8), headers: [:])
        var noBody = URLRequest(url: URL(string: "https://api.example.com/v1")!)
        noBody.httpMethod = "GET"
        let lost = NSError(domain: NSURLErrorDomain, code: NSURLErrorNetworkConnectionLost,
                           userInfo: [NSLocalizedDescriptionKey: "Empty reply from server"])
        #expect(CurlTransport.canTake(after: lost, withBody))
        #expect(!CurlTransport.canTake(after: lost, noBody))
        #expect(!CurlTransport.canTake(after: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled), withBody))
        #expect(!CurlTransport.canTake(after: ProviderError.http(status: 500, body: ""), withBody))
        #expect(!CurlTransport.canTake(after: CancellationError(), withBody))

        // The fallback alone (on Windows, requests with a body start on curl anyway).
        let first = CurlTransport.firstForBodies
        CurlTransport.firstForBodies = false
        defer { CurlTransport.firstForBodies = first }
        CurlTransport.reset()
        #expect(!CurlTransport.prefers(withBody))
        CurlTransport.prefer(withBody)
        #expect(CurlTransport.prefers(withBody))
        #expect(CurlTransport.prefers(noBody))   // the host, whatever the request
        #expect(!CurlTransport.prefers(URLRequest(url: URL(string: "https://other.example.com/v1")!)))
        CurlTransport.reset()
    }

    @Test func configQuotesAndHeads() {
        #expect(CurlTransport.quoted(#"C:\Users\a "b""#) == #""C:\\Users\\a \"b\"""#)
        let r = URLRequest.json(url: URL(string: "https://h/x")!, body: Data("{}".utf8), headers: ["Expect": "100-continue", "x-api-key": "k"])
        let c = CurlTransport.config(r, bodyFile: URL(fileURLWithPath: "/tmp/b"), maxTime: nil)
        #expect(c.contains("header = \"Expect:\""))
        #expect(!c.contains("100-continue"))
        #expect(c.lowercased().contains("header = \"x-api-key: k\""))   // corelibs capitalises header names
        #expect(c.contains(Platform.isWindows ? #"data-binary = "@\\tmp\\b""# : "data-binary = \"@/tmp/b\""))
        #expect(c.contains("request = \"POST\""))
        #expect(CurlTransport.parseHead(Data("HTTP/2 200\r\ncontent-type: text/event-stream".utf8))?.0 == 200)
        #expect(CurlTransport.parseHead(Data("HTTP/1.1 100 Continue".utf8))?.0 == 100)
        #expect(CurlTransport.parseHead(Data("HTTP/1.1 503 Busy\r\nRetry-After: 3".utf8))?.1["retry-after"] == "3")
        #expect(CurlTransport.parseHead(Data("garbage".utf8)) == nil)
        let h = CurlTransport.parseHead(Data("HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nX-Request-Id: a:b".utf8))
        #expect(h?.0 == 200)
        #expect(h?.1["content-type"] == "text/event-stream")
        #expect(h?.1["x-request-id"] == "a:b")
        #expect(h?.1.count == 2)
    }

    @Test func onWindowsRequestsWithABodyStartOnCurl() {
        guard CurlTransport.executable != nil, CurlTransport.enabled else { return }
        let was = CurlTransport.firstForBodies
        defer { CurlTransport.firstForBodies = was; CurlTransport.reset() }
        CurlTransport.reset()
        let post = URLRequest.json(url: URL(string: "https://api.deepseek.com/chat/completions")!, body: Data("{}".utf8), headers: [:])
        let get = URLRequest(url: URL(string: "https://api.deepseek.com/models")!)
        CurlTransport.firstForBodies = true
        #expect(CurlTransport.prefers(post))
        #expect(!CurlTransport.prefers(get), "a GET stays on URLSession until curl is needed for the host")
        CurlTransport.firstForBodies = false
        #expect(!CurlTransport.prefers(post))
    }

    @Test func compressedRepliesAreDecodedByCurl() {
        let plain = URLRequest.json(url: URL(string: "https://h/x")!, body: Data("{}".utf8), headers: [:])
        #expect(!CurlTransport.config(plain, bodyFile: nil, maxTime: nil).contains("\ncompressed"))
        let gz = URLRequest.json(url: URL(string: "https://h/x")!, body: Data("{}".utf8), headers: ["Accept-Encoding": "gzip"])
        #expect(CurlTransport.config(gz, bodyFile: nil, maxTime: nil).contains("\ncompressed\n"))
    }

    @Test func leftoverBodiesAreSweptButLiveOnesStay() throws {
        // Ages come from `now` (Windows refuses to back-date a directory).
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-\(UUID().uuidString)")
        let a = root.appendingPathComponent(CurlTransport.tempPrefix + "a"), b = root.appendingPathComponent(CurlTransport.tempPrefix + "b")
        let other = root.appendingPathComponent("someone-else")
        for d in [a, b, other] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        CurlTransport.sweep(olderThan: 3600, in: root)
        #expect(FileManager.default.fileExists(atPath: a.path) && FileManager.default.fileExists(atPath: b.path), "live ones stay")
        CurlTransport.sweep(olderThan: 3600, in: root, now: Date().addingTimeInterval(7200))
        #expect(!FileManager.default.fileExists(atPath: a.path) && !FileManager.default.fileExists(atPath: b.path), "leftovers go")
        #expect(FileManager.default.fileExists(atPath: other.path), "nothing else is touched")
        try? FileManager.default.removeItem(at: root)
    }

    @Test func modelCallsAreNotCutAtTheDefaultSixtySeconds() {
        let c = URLSessionStreaming.longConfiguration()
        #expect(c.timeoutIntervalForRequest >= 3600)
        #expect(c.timeoutIntervalForResource >= 86_400)
    }
}
