import Foundation

/// On-disk research state of a task (`<task>/state/`), so a resumed session continues with the
/// receipts, plan and claims its transcript refers to — instead of a fresh ledger whose `r1, r2 …`
/// would silently point at different tool calls than the ones the transcript cites.
///
/// - `receipts.jsonl` — one `Receipt` per line, append-only.
/// - `outputs/<id>.txt` — the bounded full output of each receipt (grounding corpus, `receipt` tool).
/// - `plan.json`, `claims.json` — rewritten atomically after every change.
///
/// The directory is under `.sievesci/`, which the sandbox keeps read-only for agent-run code.
enum StateFile {
    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    static func save<T: Encodable>(_ value: T, to url: URL?) {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let d = try? encoder().encode(value) else { return }
        try? d.writeReliably(to: url)
    }

    static func load<T: Decodable>(_ type: T.Type, from url: URL?) -> T? {
        guard let url, let d = FileManager.default.contents(atPath: url.path) else { return nil }
        return try? JSONDecoder().decode(T.self, from: d)
    }

    static func append<T: Encodable>(line value: T, to url: URL) {
        guard var d = try? encoder().encode(value) else { return }
        d.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: d)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? d.writeReliably(to: url)
        }
    }

    static func lines<T: Decodable>(_ type: T.Type, from url: URL) -> [T] {
        guard let t = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        return t.split(separator: "\n").compactMap { try? dec.decode(T.self, from: Data($0.utf8)) }
    }
}
