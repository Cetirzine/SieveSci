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
        let (data, resp) = try await session.data(for: request)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func postSSE(_ request: URLRequest) async throws -> HTTPStreamResponse {
        #if canImport(FoundationNetworking)
        // swift-corelibs-foundation has no URLSession.bytes(for:). Linux is only used for tests and
        // the headless CLI, so buffer the body and run it through the same SSE parser.
        let (data, resp) = try await session.data(for: request)
        let http = resp as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let headers = Self.headers(http)
        if status >= 400 {
            throw ProviderError.http(status: status, body: String(decoding: data, as: UTF8.self))
        }
        return HTTPStreamResponse(status: status, headers: headers, events: SSEDecoding.events(fromBytes: Array(data)))
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
