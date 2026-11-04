import Foundation
#if os(Windows)
import WinSDK
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif

/// A minimal HTTP/1.1 server on 127.0.0.1 over plain sockets (BSD sockets, Winsock on Windows):
/// one request per connection, answered and closed. ToolBridge uses it where Network.framework
/// does not exist (Linux, Windows). Load is a handful of tool calls at a time, so each connection
/// gets its own thread.
final class LoopbackHTTPServer: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> (String, Data)

    #if os(Windows)
    typealias RawSocket = SOCKET
    static let invalid: RawSocket = INVALID_SOCKET
    #else
    typealias RawSocket = Int32
    static let invalid: RawSocket = -1
    #endif

    let port: UInt16
    private let listener: RawSocket
    private let handler: Handler

    /// Binds an ephemeral port on 127.0.0.1 and starts accepting; nil if the socket cannot be set up.
    init?(handler: @escaping Handler) {
        Self.startup()
        let s = Self.makeSocket()
        guard s != Self.invalid else { return nil }
        var addr = sockaddr_in()
        #if canImport(Darwin)
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        #if os(Windows)
        addr.sin_family = ADDRESS_FAMILY(AF_INET)
        #else
        addr.sin_family = sa_family_t(AF_INET)
        #endif
        addr.sin_port = 0
        withUnsafeMutableBytes(of: &addr.sin_addr) { b in b[0] = 127; b[1] = 0; b[2] = 0; b[3] = 1 }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, Self.addrLength) }
        }
        guard bound == 0, listen(s, 64) == 0 else { Self.closeSocket(s); return nil }
        var actual = sockaddr_in()
        #if os(Windows)
        var len = Int32(MemoryLayout<sockaddr_in>.size)
        #else
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        #endif
        let named = withUnsafeMutablePointer(to: &actual) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard named == 0 else { Self.closeSocket(s); return nil }
        port = UInt16(bigEndian: actual.sin_port)
        listener = s
        self.handler = handler
        let t = Thread { [self] in acceptLoop() }
        t.name = "sievesci.loopback-http"
        t.start()
    }

    private func acceptLoop() {
        while true {
            let c = accept(listener, nil, nil)
            if c == Self.invalid { continue }
            let t = Thread { [self] in serve(c) }
            t.start()
        }
    }

    private func serve(_ c: RawSocket) {
        defer { Self.closeSocket(c) }
        Self.noDelay(c)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65_536)
        var request: HTTPRequest?
        var continued = false
        while request == nil {
            let n = Self.receive(c, &chunk)
            guard n > 0 else { return }
            buffer.append(contentsOf: chunk[0..<n])
            if buffer.count > 8 << 20 { return }
            request = HTTPRequest(buffer)
            // curl (URLSession off Apple platforms) asks before sending a large body and waits.
            if request == nil, !continued, let end = buffer.range(of: Data("\r\n\r\n".utf8)),
               String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self).lowercased().contains("expect: 100-continue") {
                continued = true
                Self.sendAll(c, Data("HTTP/1.1 100 Continue\r\n\r\n".utf8))
            }
        }
        guard let request else { return }
        let done = DispatchSemaphore(value: 0)
        let reply = LockedValue<(String, Data)>(("500 Internal Server Error", Data()))
        let handler = self.handler
        Task {
            let r = await handler(request)
            reply.mutate { $0 = r }
            done.signal()
        }
        done.wait()
        let (status, body) = reply.value
        var head = "HTTP/1.1 \(status)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if !body.isEmpty { head += "Content-Type: application/json\r\n" }
        Self.sendAll(c, Data((head + "\r\n").utf8) + body)
    }

    // MARK: Platform shims

    #if os(Windows)
    private static let wsa: Void = {
        var data = WSADATA()
        _ = WSAStartup(WORD(0x0202), &data)
    }()
    static func startup() { _ = wsa }
    static func noDelay(_ s: RawSocket) {
        var one: Int32 = 1
        _ = withUnsafePointer(to: &one) { p in
            p.withMemoryRebound(to: CChar.self, capacity: 4) { setsockopt(s, Int32(IPPROTO_TCP.rawValue), TCP_NODELAY, $0, 4) }
        }
    }
    static func makeSocket() -> RawSocket { socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue)) }
    static var addrLength: Int32 { Int32(MemoryLayout<sockaddr_in>.size) }
    static func closeSocket(_ s: RawSocket) { closesocket(s) }
    static func receive(_ s: RawSocket, _ buf: inout [UInt8]) -> Int {
        let cap = Int32(buf.count)
        return Int(buf.withUnsafeMutableBytes { recv(s, $0.baseAddress!.assumingMemoryBound(to: CChar.self), cap, 0) })
    }
    static func sendBytes(_ s: RawSocket, _ p: UnsafeRawBufferPointer) -> Int {
        Int(send(s, p.baseAddress!.assumingMemoryBound(to: CChar.self), Int32(p.count), 0))
    }
    #else
    static func startup() {}
    static func noDelay(_ s: RawSocket) {
        var one: Int32 = 1
        #if canImport(Glibc) || canImport(Musl)
        _ = setsockopt(s, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #else
        _ = setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
    static func makeSocket() -> RawSocket {
        #if canImport(Glibc)
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #endif
        #if canImport(Darwin)
        // A write to a closed connection fails with EPIPE instead of killing the process.
        var one: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        return s
    }
    static var addrLength: socklen_t { socklen_t(MemoryLayout<sockaddr_in>.size) }
    static func closeSocket(_ s: RawSocket) { _ = close(s) }
    static func receive(_ s: RawSocket, _ buf: inout [UInt8]) -> Int {
        let cap = buf.count
        return buf.withUnsafeMutableBytes { recv(s, $0.baseAddress, cap, 0) }
    }
    static func sendBytes(_ s: RawSocket, _ p: UnsafeRawBufferPointer) -> Int {
        #if canImport(Darwin)
        let flags: Int32 = 0
        #else
        let flags = Int32(MSG_NOSIGNAL)
        #endif
        return send(s, p.baseAddress, p.count, flags)
    }
    #endif

    static func sendAll(_ s: RawSocket, _ data: Data) {
        data.withUnsafeBytes { all in
            var offset = 0
            while offset < all.count {
                let n = sendBytes(s, UnsafeRawBufferPointer(rebasing: all[offset...]))
                if n <= 0 { return }
                offset += n
            }
        }
    }
}
