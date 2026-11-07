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
        #expect(c.contains("header = \"x-api-key: k\""))
        #expect(c.contains("data-binary = \"@/tmp/b\""))
        #expect(c.contains("request = \"POST\""))
        #expect(CurlTransport.parseHead(Data("HTTP/2 200\r\ncontent-type: text/event-stream".utf8))?.0 == 200)
        #expect(CurlTransport.parseHead(Data("HTTP/1.1 100 Continue".utf8))?.0 == 100)
        #expect(CurlTransport.parseHead(Data("HTTP/1.1 503 Busy\r\nRetry-After: 3".utf8))?.1["retry-after"] == "3")
        #expect(CurlTransport.parseHead(Data("garbage".utf8)) == nil)
    }
}
