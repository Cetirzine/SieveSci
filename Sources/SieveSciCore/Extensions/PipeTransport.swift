import Foundation
import Logging
import MCP

/// MCP over a child process's stdin/stdout using Foundation pipes: newline-delimited JSON-RPC, the
/// same framing as the SDK's `StdioTransport`, which only builds on POSIX systems. Used on Windows
/// (and in tests everywhere). Reads block on a dedicated thread, so no non-blocking descriptors are
/// needed.
actor PipeTransport: Transport {
    nonisolated let logger = Logger(label: "sievesci.mcp.pipe", factory: { _ in SwiftLogNoOpLogHandler() })
    private let reader: FileHandle
    private let writer: FileHandle
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var connected = false

    /// `reader` is the server's stdout, `writer` its stdin.
    init(reader: FileHandle, writer: FileHandle) {
        self.reader = reader
        self.writer = writer
        var c: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        stream = AsyncThrowingStream { c = $0 }
        continuation = c
    }

    func connect() async throws {
        guard !connected else { return }
        connected = true
        let reader = self.reader, continuation = self.continuation
        let t = Thread {
            var pending = Data()
            while true {
                let chunk = reader.availableData   // blocks; empty at end of file
                if chunk.isEmpty { break }
                pending.append(chunk)
                while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
                    var line = Data(pending[pending.startIndex..<nl])
                    pending = Data(pending[(nl + 1)...])
                    if line.last == UInt8(ascii: "\r") { line.removeLast() }   // a server writing CRLF
                    if !line.isEmpty { continuation.yield(line) }
                }
            }
            continuation.finish()
        }
        t.name = "sievesci.mcp.pipe"
        t.start()
    }

    func disconnect() async {
        guard connected else { return }
        connected = false
        try? writer.close()
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        guard connected else { throw MCPError.transportError(PipeTransportError.notConnected) }
        var line = data
        line.append(UInt8(ascii: "\n"))
        try writer.write(contentsOf: line)
    }

    nonisolated func receive() -> AsyncThrowingStream<Data, Swift.Error> { stream }
}

enum PipeTransportError: Error { case notConnected }
