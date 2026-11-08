import EventSource
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// One parsed server-sent event.
public struct SSEMessage: Sendable, Equatable {
    public var event: String?
    public var data: String

    public init(event: String?, data: String) {
        self.event = event
        self.data = data
    }
}

public struct HTTPStreamResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var events: AsyncThrowingStream<SSEMessage, Error>
}

/// Transport seam: production uses URLSession + the EventSource package's SSE parser; tests inject
/// recorded fixtures.
public protocol HTTPStreaming: Sendable {
    func postSSE(_ request: URLRequest) async throws -> HTTPStreamResponse
    func send(_ request: URLRequest) async throws -> (Int, Data)
}

public struct URLSessionStreaming: HTTPStreaming {
    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Int, Data) {
        #if canImport(FoundationNetworking)
        SystemProxy.refresh()
        if CurlTransport.prefers(request) {
            do { return try await CurlTransport.send(request) } catch is CurlTransport.LaunchFailed { return try await sessionSend(request) }
        }
        do { return try await sessionSend(request) } catch where CurlTransport.canTake(after: error, request) {
            let r = try await CurlTransport.send(request)
            CurlTransport.prefer(request)
            return r
        }
        #else
        return try await sessionSend(request)
        #endif
    }

    private func sessionSend(_ request: URLRequest) async throws -> (Int, Data) {
        #if canImport(FoundationNetworking)
        // The shared session's 60 s request timeout would cut a long call that asked for more.
        let s = session === URLSession.shared && request.timeoutInterval > 60 ? Self.longSession : session
        #else
        let s = session
        #endif
        let (data, resp) = try await s.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    /// Timeouts for model calls, set on the configuration itself: swift-corelibs-foundation (Windows, Linux)
    /// was seen to cut a streamed reply at about 60 s — the configuration's default — even with the
    /// request's own timeout raised. Idleness is the stall watch's job, so these are only a backstop.
    static func longConfiguration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 3600
        c.timeoutIntervalForResource = 86_400
        return c
    }

    static let longSession = URLSession(configuration: longConfiguration())

    public func postSSE(_ request: URLRequest) async throws -> HTTPStreamResponse {
        #if canImport(FoundationNetworking)
        SystemProxy.refresh()
        // URLSession here has sent a request's headers and then never its body (the server closes after
        // 15 s: "Empty reply from server", on every retry). A failure before any response goes out once
        // more through the system's curl; a host curl answered stays on curl for this run.
        if CurlTransport.prefers(request) {
            do { return try await CurlTransport.postSSE(request) } catch is CurlTransport.LaunchFailed { return try await sessionPostSSE(request) }
        }
        do { return try await sessionPostSSE(request) } catch where CurlTransport.canTake(after: error, request) {
            do {
                let r = try await CurlTransport.postSSE(request)
                CurlTransport.prefer(request)
                return r
            } catch let e as ProviderError {
                CurlTransport.prefer(request)   // curl reached the server (an HTTP error is an answer)
                throw e
            }
        }
        #else
        return try await sessionPostSSE(request)
        #endif
    }

    private func sessionPostSSE(_ request: URLRequest) async throws -> HTTPStreamResponse {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation (Windows, Linux) has no URLSession.bytes(for:): a data delegate streams
        // the body as it arrives. (Buffering it whole showed nothing until a reply ended, so a long reply
        // looked like a silent model to the stall watch and was sent again.)
        let original = request
        var request = request
        request.timeoutInterval = max(request.timeoutInterval, 3600)   // idleness is the stall watch's job
        let stream = DelegateStream()
        let session = URLSession(configuration: Self.longConfiguration(), delegate: stream, delegateQueue: nil)
        let task = session.dataTask(with: request)
        stream.task = task
        task.resume()
        let http: HTTPURLResponse
        do { http = try await stream.response() } catch { session.invalidateAndCancel(); throw error }
        let status = http.statusCode
        let headers = Self.headers(http)
        if status >= 400 {
            var body = Data()
            for try await b in stream.bytes { body.append(b); if body.count > 65536 { break } }
            session.invalidateAndCancel()
            throw ProviderError.http(status: status, body: String(decoding: body, as: UTF8.self))
        }
        let bytes = stream.bytes
        let events = AsyncThrowingStream<SSEMessage, Error> { cont in
            let t = Task {
                do {
                    for try await ev in bytes.events { cont.yield(SSEMessage(event: ev.event, data: ev.data)) }
                    cont.finish()
                } catch {
                    // The stream broke after it began, out of reach of the fallback above: the retry that
                    // follows (and the rest of the run) goes to this host through curl.
                    if !Task.isCancelled, CurlTransport.canTake(after: error, original) { CurlTransport.prefer(original) }
                    cont.finish(throwing: error)
                }
                session.finishTasksAndInvalidate()
            }
            cont.onTermination = { _ in t.cancel(); task.cancel(); session.invalidateAndCancel() }
        }
        return HTTPStreamResponse(status: status, headers: headers, events: events)
        #else
        let (bytes, resp) = try await session.bytes(for: request)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = Self.headers(http)
        if status >= 400 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 65536 { break } }
            throw ProviderError.http(status: status, body: String(decoding: body, as: UTF8.self))
        }
        let stream = AsyncThrowingStream<SSEMessage, Error> { cont in
            let task = Task {
                do {
                    for try await ev in bytes.events {
                        cont.yield(SSEMessage(event: ev.event, data: ev.data))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
        return HTTPStreamResponse(status: status, headers: headers, events: stream)
        #endif
    }

    static func headers(_ r: HTTPURLResponse?) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in r?.allHeaderFields ?? [:] {
            if let k = k as? String, let v = v as? String { out[k.lowercased()] = v }
        }
        return out
    }
}

#if canImport(FoundationNetworking)
/// Bridges URLSession's data delegate to async: the response as soon as headers arrive, then the body
/// bytes as they come.
final class DelegateStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var responseWaiter: CheckedContinuation<HTTPURLResponse, Error>?
    private var gotResponse: Result<HTTPURLResponse, Error>?
    weak var task: URLSessionDataTask?
    let bytes: AsyncThrowingStream<UInt8, Error>
    private let sink: AsyncThrowingStream<UInt8, Error>.Continuation

    override init() {
        var c: AsyncThrowingStream<UInt8, Error>.Continuation!
        bytes = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
        sink = c
        super.init()
    }

    func response() async throws -> HTTPURLResponse {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<HTTPURLResponse, Error>) in
            let ready: Result<HTTPURLResponse, Error>? = lock.withLock {
                if let r = gotResponse { return r }
                responseWaiter = k
                return nil
            }
            if let ready { k.resume(with: ready) }
        }
    }

    private func settle(_ r: Result<HTTPURLResponse, Error>) {
        let waiter: CheckedContinuation<HTTPURLResponse, Error>? = lock.withLock {
            guard gotResponse == nil else { return nil }
            gotResponse = r
            defer { responseWaiter = nil }
            return responseWaiter
        }
        waiter?.resume(with: r)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse { settle(.success(http)) }
        else { settle(.failure(ProviderError.protocolError("not an HTTP response"))) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        for b in data { sink.yield(b) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            settle(.failure(error))
            sink.finish(throwing: error)
        } else {
            settle(.failure(ProviderError.protocolError("no response")))
            sink.finish()
        }
    }
}
#endif

public enum SSEDecoding {
    /// Parses a complete SSE body with the EventSource package's parser.
    public static func events(fromBytes bytes: [UInt8]) -> AsyncThrowingStream<SSEMessage, Error> {
        let seq = ByteSequence(bytes: bytes)
        return AsyncThrowingStream { cont in
            let task = Task {
                do {
                    for try await ev in seq.events {
                        cont.yield(SSEMessage(event: ev.event, data: ev.data))
                    }
                    cont.finish()
                } catch {
                    cont.finish(throwing: error)
                }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    public static func events(fromString s: String) -> AsyncThrowingStream<SSEMessage, Error> {
        events(fromBytes: Array(s.utf8))
    }

    struct ByteSequence: AsyncSequence, Sendable {
        typealias Element = UInt8
        let bytes: [UInt8]
        struct Iterator: AsyncIteratorProtocol {
            var i = 0
            let bytes: [UInt8]
            mutating func next() async -> UInt8? {
                guard i < bytes.count else { return nil }
                defer { i += 1 }
                return bytes[i]
            }
        }
        func makeAsyncIterator() -> Iterator { Iterator(bytes: bytes) }
    }
}

/// Retries transient failures (429/5xx/transport) with exponential backoff and jitter before any
/// bytes have streamed. A retry resends identical bytes, so it still hits the prefix cache.
public enum Retry {
    public static func withBackoff<T>(attempts: Int = 4, base: Double = 1.0, _ op: () async throws -> T) async throws -> T {
        var last: Error?
        for i in 0..<attempts {
            do { return try await op() } catch {
                last = error
                let retryable: Bool
                if let pe = error as? ProviderError { retryable = pe.isRetryable }
                else { retryable = StreamWatch.isTransport(error) }
                guard retryable, i < attempts - 1 else { throw error }
                let delay = min(base * pow(2, Double(i)) + Double.random(in: 0...0.5), 30)
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw last ?? ProviderError.protocolError("retry exhausted")
    }
}

extension URLRequest {
    static func json(url: URL, body: Data, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body
        r.timeoutInterval = 600
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        r.setValue("text/event-stream", forHTTPHeaderField: "accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}
