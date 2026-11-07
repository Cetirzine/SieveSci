import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Sends a request through the system's own curl program (`curl.exe` ships with Windows 10 1803 and
/// later). On Windows the engine's URLSession (swift-corelibs-foundation over its bundled libcurl) has
/// been seen to send a request's headers and then never its body: the server waits 15 s for the body,
/// closes the connection, and the engine reports "Empty reply from server" — for every retry of that
/// request, while other clients on the same machine, network and proxy succeed. When URLSession fails
/// before any response, the request goes out once more through curl; after curl gets an answer from a
/// host, that host's requests go through curl for the rest of the run.
///
/// The API key never touches the command line or the disk: the URL and headers reach curl as a config
/// on its standard input. The body is a temporary file, deleted when curl exits.
enum CurlTransport {
    /// The curl program, if the system has one.
    static let executable: URL? = {
        let env = ProcessInfo.processInfo.environment
        #if os(Windows)
        let root = env["SystemRoot"] ?? env["windir"] ?? #"C:\Windows"#
        let candidates = [root + #"\System32\curl.exe"#]
        #else
        _ = env
        let candidates = ["/usr/bin/curl", "/bin/curl", "/usr/local/bin/curl"]
        #endif
        return candidates.first { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }()

    private static let preferred = LockedValue<Set<String>>([])

    private static func hostKey(_ request: URLRequest) -> String? {
        guard let u = request.url, let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = u.host?.lowercased() else { return nil }
        return "\(scheme)://\(host):\(u.port ?? (scheme == "https" ? 443 : 80))"
    }

    /// curl answered this host before: send its requests through curl first.
    static func prefers(_ request: URLRequest) -> Bool {
        guard executable != nil, let k = hostKey(request) else { return false }
        return preferred.value.contains(k)
    }

    static func prefer(_ request: URLRequest) {
        guard let k = hostKey(request) else { return }
        preferred.mutate { $0.insert(k) }
    }

    /// Forget preferences (tests).
    static func reset() { preferred.mutate { $0.removeAll() } }

    /// URLSession failed before any response arrived, in a way another HTTP stack may not: a request
    /// with a body, a network-level error, not a Stop.
    static func canTake(after error: Error, _ request: URLRequest) -> Bool {
        guard executable != nil, hostKey(request) != nil, request.httpBody?.isEmpty == false, !Task.isCancelled else { return false }
        if error is ProviderError || error is CancellationError { return false }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            return ![NSURLErrorCancelled, NSURLErrorBadURL, NSURLErrorUnsupportedURL, NSURLErrorUserCancelledAuthentication].contains(ns.code)
        }
        return StreamWatch.isTransport(error)
    }

    // MARK: Requests

    static func postSSE(_ request: URLRequest) async throws -> HTTPStreamResponse {
        let exchange = try Exchange.start(request, maxTime: nil)
        let (status, headers) = try await withTaskCancellationHandler {
            try await exchange.response()
        } onCancel: { exchange.stop() }
        if status >= 400 {
            let body = try await exchange.collect(limit: 65_536)
            exchange.stop()
            throw ProviderError.http(status: status, body: String(decoding: body, as: UTF8.self))
        }
        let bytes = exchange.bytes
        let events = AsyncThrowingStream<SSEMessage, Error> { cont in
            let t = Task {
                do {
                    for try await ev in bytes.events { cont.yield(SSEMessage(event: ev.event, data: ev.data)) }
                    cont.finish()
                } catch { cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in t.cancel(); exchange.stop() }
        }
        return HTTPStreamResponse(status: status, headers: headers, events: events)
    }

    static func send(_ request: URLRequest) async throws -> (Int, Data) {
        let limit = request.timeoutInterval > 0 && request.timeoutInterval < 3600 ? request.timeoutInterval : nil
        let exchange = try Exchange.start(request, maxTime: limit)
        return try await withTaskCancellationHandler {
            let (status, _) = try await exchange.response()
            return (status, try await exchange.collect(limit: nil))
        } onCancel: { exchange.stop() }
    }

    /// curl's config syntax: a double-quoted string with backslash escapes.
    static func quoted(_ s: String) -> String {
        var out = "\""
        for ch in s {
            switch ch {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.append(ch)
            }
        }
        return out + "\""
    }

    static func config(_ request: URLRequest, bodyFile: URL?, maxTime: Double?) -> String {
        var lines = ["url = " + quoted(request.url?.absoluteString ?? "")]
        lines.append("request = " + quoted(request.httpMethod ?? (bodyFile == nil ? "GET" : "POST")))
        for (k, v) in (request.allHTTPHeaderFields ?? [:]).sorted(by: { $0.key < $1.key })
        where k.lowercased() != "expect" && k.lowercased() != "content-length" {
            lines.append("header = " + quoted("\(k): \(v)"))
        }
        // No 100-continue round trip: the body goes right after the headers.
        lines.append("header = " + quoted("Expect:"))
        if let bodyFile {
            // curl.exe needs C:\…, not URL's /C:/… form.
            let path = Platform.isWindows ? Platform.windowsPath(bodyFile.path) : bodyFile.path
            lines.append("data-binary = " + quoted("@" + path))
        }
        if let maxTime { lines.append("max-time = \(Int(maxTime.rounded(.up)))") }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The status and headers of a response as curl prints them (`--include`); informational (1xx)
    /// blocks are skipped by the caller. nil until a status line is found.
    static func parseHead(_ block: Data) -> (Int, [String: String])? {
        // Split on bytes: off Apple platforms "\r\n" is one Character and `components(separatedBy: "\n")` misses it.
        let lines = block.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = lines.first, first.hasPrefix("HTTP/") else { return nil }
        let parts = first.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2, let status = Int(parts[1]) else { return nil }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return (status, headers)
    }

    /// curl's exit status as a network error, so the retry and stall logic treat it as URLSession's.
    static func failure(_ code: Int32, _ message: String) -> Error {
        let m = message.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = m.isEmpty ? "curl exited with code \(code)" : m
        let urlCode: Int = switch code {
        case 6: NSURLErrorCannotFindHost
        case 7: NSURLErrorCannotConnectToHost
        case 28: NSURLErrorTimedOut
        default: NSURLErrorNetworkConnectionLost
        }
        return NSError(domain: NSURLErrorDomain, code: urlCode, userInfo: [NSLocalizedDescriptionKey: text])
    }

    // MARK: One curl run

    final class Exchange: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<(Int, [String: String]), Error>?
        private var head: Result<(Int, [String: String]), Error>?
        private var stopped = false
        private let process = Process()
        private let dir: URL
        let bytes: AsyncThrowingStream<UInt8, Error>
        private let sink: AsyncThrowingStream<UInt8, Error>.Continuation

        private init(dir: URL) {
            self.dir = dir
            var c: AsyncThrowingStream<UInt8, Error>.Continuation!
            bytes = AsyncThrowingStream(bufferingPolicy: .unbounded) { c = $0 }
            sink = c
        }

        static func start(_ request: URLRequest, maxTime: Double?) throws -> Exchange {
            guard let exe = CurlTransport.executable else { throw ProviderError.cliNotFound("curl") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sievesci-curl-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var bodyFile: URL?
            if let body = request.httpBody, !body.isEmpty {
                let f = dir.appendingPathComponent("body")
                try body.write(to: f)
                bodyFile = f
            }
            let x = Exchange(dir: dir)
            let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
            x.process.executableURL = exe
            // -q first: no ~/.curlrc; the config (URL, headers, body file) comes on stdin.
            x.process.arguments = ["-q", "--config", "-", "--silent", "--show-error", "--no-buffer", "--include",
                                   "--suppress-connect-headers", "--connect-timeout", "30"]
            x.process.standardInput = stdin
            x.process.standardOutput = stdout
            x.process.standardError = stderr
            do { try x.process.run() } catch {
                try? FileManager.default.removeItem(at: dir)
                throw error
            }
            Signals.ignoreBrokenPipes()   // curl gone already: a failed write, not a killed engine
            try? stdin.fileHandleForWriting.write(contentsOf: Data(CurlTransport.config(request, bodyFile: bodyFile, maxTime: maxTime).utf8))
            try? stdin.fileHandleForWriting.close()

            let errText = LockedValue(Data())
            let errDone = DispatchSemaphore(value: 0)
            let errThread = Thread {
                let d = stderr.fileHandleForReading.readDataToEndOfFile()
                errText.mutate { $0 = d }
                errDone.signal()
            }
            errThread.start()
            let outThread = Thread { x.pump(stdout.fileHandleForReading, errText: errText, errDone: errDone) }
            outThread.name = "sievesci.curl"
            outThread.start()
            return x
        }

        /// Reads curl's output: the response head (skipping 1xx), then the body as it arrives.
        private func pump(_ out: FileHandle, errText: LockedValue<Data>, errDone: DispatchSemaphore) {
            var pending = Data()
            var inBody = false
            while true {
                let d = out.availableData
                if d.isEmpty { break }
                if inBody { for b in d { sink.yield(b) }; continue }
                pending.append(d)
                while !inBody {
                    let crlf = pending.range(of: Data("\r\n\r\n".utf8)), lf = pending.range(of: Data("\n\n".utf8))
                    guard let end = [crlf, lf].compactMap({ $0 }).min(by: { $0.lowerBound < $1.lowerBound }) else { break }
                    let block = pending.subdata(in: pending.startIndex..<end.lowerBound)
                    pending = pending.subdata(in: end.upperBound..<pending.endIndex)
                    guard let (status, headers) = CurlTransport.parseHead(block) else { continue }
                    // 1xx, and a proxy's tunnel reply should --suppress-connect-headers not apply.
                    if (100..<200).contains(status) { continue }
                    if status == 200, String(decoding: block.prefix(80), as: UTF8.self).lowercased().contains("connection established") { continue }
                    settle(.success((status, headers)))
                    inBody = true
                    for b in pending { sink.yield(b) }
                    pending = Data()
                }
                if !inBody, pending.count > 1 << 20 { stop(); break }
            }
            process.waitUntilExit()
            errDone.wait()
            try? FileManager.default.removeItem(at: dir)
            let code = process.terminationStatus
            if code != 0 || !inBody {
                let error = lock.withLock { stopped }
                    ? NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled, userInfo: [NSLocalizedDescriptionKey: "cancelled"])
                    : CurlTransport.failure(code == 0 ? 52 : code, String(decoding: errText.value, as: UTF8.self))
                settle(.failure(error))
                sink.finish(throwing: error)
            } else {
                sink.finish()
            }
        }

        private func settle(_ r: Result<(Int, [String: String]), Error>) {
            let w: CheckedContinuation<(Int, [String: String]), Error>? = lock.withLock {
                guard head == nil else { return nil }
                head = r
                defer { waiter = nil }
                return waiter
            }
            w?.resume(with: r)
        }

        func response() async throws -> (Int, [String: String]) {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<(Int, [String: String]), Error>) in
                let ready: Result<(Int, [String: String]), Error>? = lock.withLock {
                    if let h = head { return h }
                    waiter = k
                    return nil
                }
                if let ready { k.resume(with: ready) }
            }
        }

        /// The rest of the body (up to `limit` bytes).
        func collect(limit: Int?) async throws -> Data {
            var body = Data()
            for try await b in bytes {
                body.append(b)
                if let limit, body.count >= limit { break }
            }
            return body
        }

        /// Ends the run (Stop, a dropped stream, or a reply already read).
        func stop() {
            lock.withLock { stopped = true }
            if process.isRunning { process.terminate() }
        }
    }
}
