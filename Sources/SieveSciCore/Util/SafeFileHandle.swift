import Foundation

/// The old `FileHandle` calls (`readDataToEndOfFile`, `readData(ofLength:)`, `seekToEndOfFile`,
/// `write(_:)`) raise Objective-C exceptions on I/O errors — a log deleted under a tailing job, a pipe
/// whose reader exited — which Swift cannot catch, so they abort the app. These wrappers use the
/// throwing APIs instead and treat a failure as "nothing read / nothing written".
public extension FileHandle {
    /// Everything from the current offset to the end (empty on error).
    func readRest() -> Data { ((try? readToEnd()) ?? nil) ?? Data() }

    /// Up to `count` bytes (empty at end of file or on error).
    func readSome(_ count: Int) -> Data { ((try? read(upToCount: count)) ?? nil) ?? Data() }

    /// Writes `data`; false when the file or pipe is gone.
    @discardableResult func writeSafely(_ data: Data) -> Bool {
        do { try write(contentsOf: data); return true } catch { return false }
    }

    /// Appends `data` at the end of the file.
    @discardableResult func appendSafely(_ data: Data) -> Bool {
        do { _ = try seekToEnd(); try write(contentsOf: data); return true } catch { return false }
    }
}

extension String {
    /// Writes the file atomically, retrying once and then writing in place: on Windows the final
    /// rename of an atomic write can fail while a scanner or indexer briefly holds the file.
    public func writeReliably(to url: URL) throws {
        do { try write(to: url, atomically: true, encoding: .utf8); return } catch {}
        Thread.sleep(forTimeInterval: 0.1)
        do { try write(to: url, atomically: true, encoding: .utf8); return } catch {}
        try write(to: url, atomically: false, encoding: .utf8)
    }
}

public enum Signals {
    /// A write to a pipe whose reader has exited sends SIGPIPE, which by default kills the process
    /// without a crash report. Ignored, the write fails with EPIPE and `writeSafely` returns false.
    public static func ignoreBrokenPipes() {
        #if !os(Windows)   // Windows has no SIGPIPE: a broken pipe is just a failed write.
        signal(SIGPIPE, SIG_IGN)
        #endif
    }
}
