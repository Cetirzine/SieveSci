import Foundation

/// Line diff for the Changes panel and inline edit views. Built on the standard library's
/// `CollectionDifference` (Myers' algorithm), grouped into unified-diff hunks with context.
public struct FileDiff: Sendable, Equatable {
    public enum LineKind: Sendable, Equatable { case context, added, removed }
    public struct Line: Sendable, Equatable {
        public var kind: LineKind
        public var text: String
        public var oldNumber: Int?
        public var newNumber: Int?
    }
    public struct Hunk: Sendable, Equatable {
        public var header: String
        public var lines: [Line]
    }

    public var path: String
    public var hunks: [Hunk]
    public var added: Int
    public var removed: Int
    public var isNewFile: Bool
    public var isBinaryOrLarge: Bool

    public static func make(path: String, old: String?, new: String?, context: Int = 3) -> FileDiff {
        let a = (old ?? "").isEmpty ? [] : (old ?? "").components(separatedBy: "\n")
        let b = (new ?? "").isEmpty ? [] : (new ?? "").components(separatedBy: "\n")
        if a.count + b.count > 40_000 {
            return FileDiff(path: path, hunks: [], added: 0, removed: 0, isNewFile: old == nil, isBinaryOrLarge: true)
        }
        let diff = b.difference(from: a)
        var removedAt = Set<Int>(), insertedAt = Set<Int>()
        for c in diff {
            switch c {
            case .remove(let o, _, _): removedAt.insert(o)
            case .insert(let o, _, _): insertedAt.insert(o)
            }
        }
        // Walk both sequences to produce an ordered line list.
        var lines: [Line] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            if i < a.count, removedAt.contains(i) {
                lines.append(Line(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil)); i += 1
            } else if j < b.count, insertedAt.contains(j) {
                lines.append(Line(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1)); j += 1
            } else if i < a.count, j < b.count {
                lines.append(Line(kind: .context, text: b[j], oldNumber: i + 1, newNumber: j + 1)); i += 1; j += 1
            } else if i < a.count {
                lines.append(Line(kind: .removed, text: a[i], oldNumber: i + 1, newNumber: nil)); i += 1
            } else {
                lines.append(Line(kind: .added, text: b[j], oldNumber: nil, newNumber: j + 1)); j += 1
            }
        }
        // Group changes into hunks with `context` lines around them.
        let changed = lines.indices.filter { lines[$0].kind != .context }
        var hunks: [Hunk] = []
        var k = 0
        while k < changed.count {
            let start = max(0, changed[k] - context)
            var end = min(lines.count - 1, changed[k] + context)
            k += 1
            while k < changed.count, changed[k] - context <= end + 1 {
                end = min(lines.count - 1, changed[k] + context)
                k += 1
            }
            let slice = Array(lines[start...end])
            let o = slice.first { $0.oldNumber != nil }?.oldNumber ?? 0
            let n = slice.first { $0.newNumber != nil }?.newNumber ?? 0
            let oc = slice.filter { $0.kind != .added }.count, nc = slice.filter { $0.kind != .removed }.count
            hunks.append(Hunk(header: "@@ -\(o),\(oc) +\(n),\(nc) @@", lines: slice))
        }
        return FileDiff(path: path, hunks: hunks, added: lines.filter { $0.kind == .added }.count,
                        removed: lines.filter { $0.kind == .removed }.count, isNewFile: old == nil, isBinaryOrLarge: false)
    }

    /// Unified diff text (for export / copying).
    public var unified: String {
        var s = "--- \(isNewFile ? "/dev/null" : "a/" + path)\n+++ b/\(path)\n"
        for h in hunks {
            s += h.header + "\n"
            for l in h.lines { s += (l.kind == .added ? "+" : l.kind == .removed ? "-" : " ") + l.text + "\n" }
        }
        return s
    }
}
