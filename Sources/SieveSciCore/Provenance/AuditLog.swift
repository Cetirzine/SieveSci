import Foundation

/// Append-only, hash-chained provenance log (one JSON object per line).
///
/// Every step leaves a trace: model requests (provider, model, prefix fingerprint, token and cache
/// usage), tool calls with inputs and output digests, file fingerprints, plan revisions,
/// checkpoint reviews, verifications, permission decisions and hook outcomes. Each entry carries
/// `prev` (the previous entry's hash) and `hash` = sha256(prev + canonical body), so any later edit
/// or deletion is detectable with `verify()` — suitable for lab-notebook / research-integrity audits.
public final class AuditLog: @unchecked Sendable {
    public struct Entry: Codable, Sendable {
        public var seq: Int
        public var time: Date
        public var session: String
        public var kind: String
        public var actor: String          // "user", "main", "checker", "verifier", "worker", "host"
        public var data: JSON
        public var prev: String
        public var hash: String
    }

    public let url: URL
    private let lock = NSLock()
    private var lastHash: String
    private var seq: Int
    private var listeners: [(Entry) -> Void] = []

    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        // Only the last entry is needed to continue the chain; logs reach tens of MB.
        let last = Self.lastEntry(url)
        lastHash = last?.hash ?? String(repeating: "0", count: 64)
        seq = last?.seq ?? 0
    }

    /// The newest entry's sequence number and hash, without reading the file.
    public var head: (seq: Int, hash: String) { lock.lock(); defer { lock.unlock() }; return (seq, lastHash) }

    public func onAppend(_ f: @escaping (Entry) -> Void) {
        lock.lock(); listeners.append(f); lock.unlock()
    }

    static func digest(prev: String, seq: Int, time: Date, session: String, kind: String, actor: String, data: JSON) -> String {
        let iso = isoFormatter.string(from: time)
        let body: JSON = ["seq": .int(seq), "time": .string(iso), "session": .string(session), "kind": .string(kind),
                          "actor": .string(actor), "data": data]
        return Hashing.sha256Hex(prev + body.canonical)
    }

    @discardableResult
    public func append(session: String, kind: String, actor: String, _ data: JSON) -> Entry {
        lock.lock()
        seq += 1
        // Second precision so the timestamp round-trips through ISO-8601 and verify() can recompute.
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let h = Self.digest(prev: lastHash, seq: seq, time: now, session: session, kind: kind, actor: actor, data: data)
        let e = Entry(seq: seq, time: now, session: session, kind: kind, actor: actor, data: data, prev: lastHash, hash: h)
        lastHash = h
        if let line = try? JSONCodec.canonicalData(encodable: e), let fh = try? FileHandle(forWritingTo: url) {
            fh.appendSafely(line + Data("\n".utf8))
            try? fh.close()
        }
        let ls = listeners
        lock.unlock()
        for l in ls { l(e) }
        return e
    }

    /// All entries, or only those of the given kinds. Lines of other kinds are skipped before decoding
    /// (canonical encoding writes `"kind":"…"` verbatim), which keeps reopening a long task fast.
    public static func read(_ url: URL, kinds: Set<String>? = nil) throws -> [Entry] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let needles: [[UInt8]]? = kinds.map { ks in ks.map { Array("\"kind\":\"\($0)\"".utf8) } }
        var out: [Entry] = []
        data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            guard let base = buf.baseAddress else { return }
            var start = 0
            while start < buf.count {
                let line = base + start
                let len: Int
                if let nl = memchr(line, 0x0A, buf.count - start) { len = base.distance(to: UnsafeRawPointer(nl)) - start } else { len = buf.count - start }
                defer { start += len + 1 }
                guard len > 0, wanted(line, len, needles) else { continue }
                guard let e = try? decode(Data(bytes: line, count: len)) else { continue }
                if kinds == nil || kinds!.contains(e.kind) { out.append(e) }
            }
        }
        return out
    }

    private static func wanted(_ line: UnsafeRawPointer, _ len: Int, _ needles: [[UInt8]]?) -> Bool {
        guard let needles else { return true }
        for n in needles where n.withUnsafeBytes({ memmem(line, len, $0.baseAddress, n.count) }) != nil { return true }
        return false
    }

    /// The entries appended since byte `offset` (complete lines only) and the offset to resume from.
    /// Lets a live view follow the log without re-decoding all of it.
    public static func readNew(_ url: URL, from offset: UInt64) -> (entries: [Entry], offset: UInt64) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], offset) }
        defer { try? h.close() }
        guard (try? h.seek(toOffset: offset)) != nil else { return ([], offset) }
        let d = h.readRest()
        guard let end = d.lastIndex(of: UInt8(ascii: "\n")) else { return ([], offset) }
        let entries = d[d.startIndex...end].split(separator: UInt8(ascii: "\n")).compactMap { try? decode(Data($0)) }
        return (entries, offset + UInt64(end - d.startIndex + 1))
    }

    /// The last complete, decodable entry, read from the end of the file.
    static func lastEntry(_ url: URL) -> Entry? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let size = try? h.seekToEnd(), size > 0 else { return nil }
        var window: UInt64 = 64 * 1024
        while true {
            let start = size > window ? size - window : 0
            guard (try? h.seek(toOffset: start)) != nil else { return nil }
            let d = h.readRest()
            // A torn final line (crash mid-write) is skipped; the first line of a partial window may be cut.
            var lines = d.split(separator: UInt8(ascii: "\n"))
            if start > 0, !lines.isEmpty { lines.removeFirst() }
            if let e = lines.reversed().lazy.compactMap({ try? decode(Data($0)) }).first { return e }
            if start == 0 { return nil }
            window *= 4
        }
    }

    static let isoFormatter = ISO8601DateFormatter()

    /// `yyyy-MM-ddTHH:mm:ssZ` (what `append` writes) without a formatter, which dominated decoding time.
    static func parseTime(_ s: String) -> Date? {
        let u = Array(s.utf8)
        guard u.count == 20, u[4] == 45, u[7] == 45, u[10] == 84, u[13] == 58, u[16] == 58, u[19] == 90 else { return isoFormatter.date(from: s) }
        func n(_ a: Int, _ b: Int) -> Int? {
            var v = 0
            for i in a..<b { let d = Int(u[i]) - 48; guard (0...9).contains(d) else { return nil }; v = v * 10 + d }
            return v
        }
        guard let y = n(0, 4), let mo = n(5, 7), let d = n(8, 10), let h = n(11, 13), let mi = n(14, 16), let se = n(17, 19),
              (1...12).contains(mo), (1...31).contains(d) else { return isoFormatter.date(from: s) }
        // Days from civil (Howard Hinnant), UTC.
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Date(timeIntervalSince1970: TimeInterval(days * 86400 + h * 3600 + mi * 60 + se))
    }

    static func decode(_ line: Data) throws -> Entry {
        let j = try JSONCodec.parse(line)
        guard let seq = j["seq"]?.intValue, let t = j.str("time"), let time = parseTime(t),
              let kind = j.str("kind"), let prev = j.str("prev"), let hash = j.str("hash") else {
            throw ProviderError.protocolError("malformed audit entry")
        }
        return Entry(seq: seq, time: time, session: j.str("session") ?? "", kind: kind, actor: j.str("actor") ?? "",
                     data: j["data"] ?? .null, prev: prev, hash: hash)
    }

    /// Recomputes the chain. Returns the first broken sequence number, or nil if intact.
    public static func verify(_ url: URL) throws -> Int? {
        var prev = String(repeating: "0", count: 64)
        for e in try read(url) {
            let h = digest(prev: prev, seq: e.seq, time: e.time, session: e.session, kind: e.kind, actor: e.actor, data: e.data)
            if e.prev != prev || e.hash != h { return e.seq }
            prev = e.hash
        }
        return nil
    }
}
