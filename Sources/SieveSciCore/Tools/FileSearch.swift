import Foundation
#if os(Windows)
import ucrt
#endif

/// Searching the workspace without stalling on it.
///
/// A research workspace is not a source tree: it holds gigabytes of tables, structures and model
/// files. The first content search read every file whole into a `String` and ran the expression on
/// each line (one checker `grep` took 36 minutes on a 94 GB workspace). This one
/// - walks the tree once, leaving out dependency and cache folders and files that are not text;
/// - searches bytes (memory-mapped) for the pattern's literals, and runs the regular expression only
///   on the lines that hold one — a file without a hit costs one pass over its bytes;
/// - works on several files at once;
/// - stops at a deadline and returns what it found, saying so, instead of holding the agent.
/// The design follows ripgrep's (literal prefilter, binary detection, size limits, parallel walk);
/// ripgrep itself is used when it is installed.
public enum FileSearch {
    /// Folders whose contents are never what a search is for (dependencies, caches, version control).
    public static let skippedFolders: Set<String> = [
        "node_modules", ".build", "__pycache__", ".venv", "venv", "site-packages", ".git", ".hg", ".svn",
        ".mypy_cache", ".pytest_cache", ".ipynb_checkpoints", ".tox", ".cache", "DerivedData",
    ]

    /// Extensions that are never text.
    static let binaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "webp", "bmp", "tif", "tiff", "ico", "icns", "pdf", "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "rar", "tar",
        "npy", "npz", "pkl", "pickle", "pt", "pth", "ckpt", "safetensors", "onnx", "h5", "hdf5", "h5ad", "parquet", "feather", "arrow", "db", "sqlite",
        "bam", "bai", "cram", "bcf", "tbi", "2bit", "bw", "bigwig", "mmtf", "bcif", "dcd", "xtc", "trr", "so", "dylib", "dll", "exe", "o", "a", "class",
        "jar", "wasm", "pyc", "mp3", "mp4", "mov", "avi", "mkv", "wav", "ttf", "otf", "woff", "woff2", "docx", "xlsx", "pptx", "dmg", "iso", "bin",
    ]

    public struct Entry: Sendable {
        public var url: URL
        public var size: Int
    }

    public struct Walk: Sendable {
        public var files: [Entry] = []
        /// The walk stopped early (deadline or file limit): the list is partial.
        public var truncated = false
    }

    /// Regular files under `root` (or `root` itself when it is a file), hidden files and skipped folders
    /// left out. `maxDepth` 1 lists only the folder's own files.
    public static func walk(_ root: URL, maxDepth: Int? = nil, limit: Int = 200_000, deadline: Date) -> Walk {
        var out = Walk()
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDir) else { return out }
        if !isDir.boolValue {
            let size = (try? root.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            out.files = [Entry(url: root, size: size)]
            return out
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .fileSizeKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return out }
        var seen = 0
        // The enumerator may spell the root another way (/var → /private/var): results are re-rooted on
        // the path that was asked for, so callers can cut it off again.
        let asked = root.path.hasSuffix("/") ? String(root.path.dropLast()) : root.path
        var spelled: String?
        let keySet = Set(keys)
        for case let found as URL in en {
            seen += 1
            if seen % 512 == 0, Date() > deadline || Task.isCancelled { out.truncated = true; break }
            // Read from the enumerator's own URL, which carries the prefetched values.
            let v = try? found.resourceValues(forKeys: keySet)
            if spelled == nil {
                // The first item is `level` components below the root.
                var top = found
                for _ in 0..<en.level { top.deleteLastPathComponent() }
                spelled = top.path.hasSuffix("/") ? String(top.path.dropLast()) : top.path
            }
            var u = found
            if let sp = spelled, sp != asked, v?.isRegularFile == true, u.path.hasPrefix(sp + "/") { u = URL(fileURLWithPath: asked + u.path.dropFirst(sp.count)) }
            if v?.isDirectory == true {
                if skippedFolders.contains(u.lastPathComponent) || (maxDepth.map { en.level >= $0 } ?? false) { en.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true else { continue }
            out.files.append(Entry(url: u, size: v?.fileSize ?? 0))
            if out.files.count >= limit { out.truncated = true; break }
        }
        return out
    }

    // MARK: Literals

    /// The pattern as a list of plain strings, when it is nothing but plain strings joined by `|`
    /// (`0\.8096|0\.4312`, `n_entity_clusters`). Any other expression gives nil.
    static func literals(of pattern: String) -> [String]? {
        var out: [String] = [], cur = ""
        var it = pattern.makeIterator()
        while let c = it.next() {
            switch c {
            case "|":
                out.append(cur); cur = ""
            case "\\":
                // An escaped punctuation mark is that mark; an escaped letter or digit is a class or an anchor.
                guard let n = it.next(), !n.isLetter, !n.isNumber else { return nil }
                cur.append(n)
            case ".", "^", "$", "*", "+", "?", "(", ")", "[", "]", "{", "}":
                return nil
            default:
                cur.append(c)
            }
        }
        out.append(cur)
        // An empty alternative matches every line; very short ones filter nothing.
        return out.allSatisfy { $0.utf8.count >= 2 } ? out : nil
    }

    /// First position of `needle` in `hay` at or after `from`.
    static func find(_ needle: [UInt8], in hay: UnsafeRawBufferPointer, from: Int) -> Int? {
        guard let base = hay.baseAddress, !needle.isEmpty, from >= 0, hay.count - from >= needle.count else { return nil }
        #if canImport(Darwin)
        // The C library's substring search (vectorised, two-way): far faster than stepping from one
        // candidate byte to the next in tables full of digits.
        return needle.withUnsafeBytes { n -> Int? in
            guard let p = memmem(base + from, hay.count - from, n.baseAddress!, n.count) else { return nil }
            return base.distance(to: UnsafeRawPointer(p))
        }
        #else
        // No memmem on Windows (and not always exposed on Linux): look for the needle's rarest byte, then compare around it.
        let k = anchor(needle)
        return needle.withUnsafeBytes { n -> Int? in
            var at = from + k
            let last = hay.count - needle.count + k
            while at <= last {
                guard let p = memchr(base + at, Int32(needle[k]), last - at + 1) else { return nil }
                let i = base.distance(to: UnsafeRawPointer(p)) - k
                if memcmp(base + i, n.baseAddress!, needle.count) == 0 { return i }
                at = i + k + 1
            }
            return nil
        }
        #endif
    }

    /// The position of the byte least likely to occur in text and tables: punctuation and capitals
    /// before lower-case letters, letters before digits, spaces and separators last.
    static func anchor(_ needle: [UInt8]) -> Int {
        func commonness(_ b: UInt8) -> Int {
            switch b {
            case 0x20, 0x09, 0x2C, 0x2E, 0x2D: return 5          // space, tab, comma, full stop, minus
            case 0x30...0x39: return 4                             // digits
            case 0x61...0x7A: return "etaoinsrhl".utf8.contains(b) ? 3 : 2
            case 0x41...0x5A: return 1
            default: return 0
            }
        }
        return needle.indices.min { commonness(needle[$0]) < commonness(needle[$1]) } ?? 0
    }

    static func countNewlines(_ hay: UnsafeRawBufferPointer, _ range: Range<Int>) -> Int {
        guard let base = hay.baseAddress, !range.isEmpty else { return 0 }
        var n = 0, at = range.lowerBound
        while at < range.upperBound, let p = memchr(base + at, 0x0A, range.upperBound - at) {
            n += 1
            at = base.distance(to: UnsafeRawPointer(p)) + 1
        }
        return n
    }

    // MARK: Grep

    public struct Options: Sendable {
        public var ignoreCase = false
        /// Matches kept per file, and in all.
        public var perFile = 50, total = 500
        public var maxLine = 400
        /// Files larger than this are named, not searched (unless the search is of that one file).
        public var maxFileBytes = 256 << 20
        public var seconds: TimeInterval = 20
        public init() {}
    }

    public struct Result: Sendable {
        public var lines: [String] = []
        public var filesSearched = 0, filesTotal = 0
        public var skippedLarge: [String] = []
        /// Why the result is partial, when it is.
        public var note: String?
    }

    /// Lines matching `pattern` in the files `accept` lets through.
    public static func grep(pattern: String, root: URL, options: Options = Options(),
                            accept: @escaping @Sendable (URL) -> Bool = { _ in true }) async throws -> Result {
        let re = try NSRegularExpression(pattern: pattern, options: options.ignoreCase ? [.caseInsensitive] : [])
        // For a first look at a whole piece of a file: `^` and `$` are line ends there.
        let pieceRe = try NSRegularExpression(pattern: pattern, options: options.ignoreCase ? [.caseInsensitive, .anchorsMatchLines] : [.anchorsMatchLines])
        let deadline = Date().addingTimeInterval(options.seconds)
        let walk = Self.walk(root, deadline: Date().addingTimeInterval(options.seconds / 2))
        let single = walk.files.count == 1 && walk.files[0].url.path == root.path
        var result = Result()
        var files: [Entry] = []
        for f in walk.files {
            if !single, binaryExtensions.contains(f.url.pathExtension.lowercased()) { continue }
            guard f.size > 0, accept(f.url) else { continue }
            if !single, f.size > options.maxFileBytes { result.skippedLarge.append(f.url.path); continue }
            files.append(f)
        }
        result.filesTotal = files.count
        let needles = options.ignoreCase ? nil : literals(of: pattern)?.map { Array($0.utf8) }
        let next = LockedValue(0), found = LockedValue(0)
        let workers = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1, files.count))
        let perFile: [(Int, [String])] = await withTaskGroup(of: [(Int, [String])].self) { group in
            for _ in 0..<workers {
                group.addTask {
                    var mine: [(Int, [String])] = []
                    while true {
                        var i = 0
                        next.mutate { i = $0; $0 += 1 }
                        guard i < files.count, Date() < deadline, !Task.isCancelled, found.value < options.total else { break }
                        let hits = search(files[i].url, re: re, pieceRe: pieceRe, needles: needles, options: options, deadline: deadline)
                        if !hits.isEmpty { found.mutate { $0 += hits.count } }
                        mine.append((i, hits))
                    }
                    return mine
                }
            }
            var all: [(Int, [String])] = []
            for await part in group { all += part }
            return all
        }
        result.filesSearched = perFile.count
        result.lines = Array(perFile.sorted { $0.0 < $1.0 }.flatMap(\.1).prefix(options.total))
        var notes: [String] = []
        if found.value >= options.total { notes.append("more than \(options.total) matching lines; only the first \(options.total) are shown") }
        else if result.filesSearched < result.filesTotal {
            notes.append("stopped after \(Int(options.seconds)) s with \(result.filesSearched) of \(walk.truncated ? "more than " : "")\(result.filesTotal) files searched")
        } else if walk.truncated {
            notes.append("the folder holds more files than one search covers; the first \(walk.files.count) were searched")
        }
        if !result.skippedLarge.isEmpty {
            notes.append("\(result.skippedLarge.count) file(s) over \(options.maxFileBytes >> 20) MB were not searched (\(result.skippedLarge.prefix(3).map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))\(result.skippedLarge.count > 3 ? ", …" : "")): give one as `path` to search it")
        }
        if !notes.isEmpty { result.note = notes.joined(separator: "; ") + ". Narrow `path` or `glob` for a complete answer." }
        return result
    }

    /// One file's matching lines as `path:line:text`.
    static func search(_ url: URL, re: NSRegularExpression, pieceRe: NSRegularExpression, needles: [[UInt8]]?, options: Options, deadline: Date) -> [String] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else { return [] }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> [String] in
            // A NUL in the first bytes: not text.
            if memchr(buf.baseAddress!, 0, min(buf.count, 4096)) != nil { return [] }
            var out: [String] = []
            func lineBounds(_ at: Int) -> Range<Int> {
                var s = at, e = at
                while s > 0, buf[s - 1] != 0x0A { s -= 1 }
                while e < buf.count, buf[e] != 0x0A { e += 1 }
                return s..<e
            }
            func emit(_ r: Range<Int>, _ number: Int) {
                var text = String(decoding: UnsafeRawBufferPointer(rebasing: buf[r]), as: UTF8.self)
                if text.hasSuffix("\r") { text.removeLast() }
                guard re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else { return }
                out.append("\(url.path):\(number):\(text.truncated(options.maxLine, marker: "…"))")
            }
            if let needles {
                // Literal pattern: jump from occurrence to occurrence; the expression confirms each line.
                var at = 0, line = 1, counted = 0
                // Each literal's next occurrence is remembered: one that is not in the rest of the file is
                // never looked for again (searching from every hit made a file cost hits × size).
                var nextAt = [Int?](repeating: -1, count: needles.count)
                while out.count < options.perFile, at < buf.count {
                    var best: Int?
                    for (k, n) in needles.enumerated() {
                        if let known = nextAt[k], known < at { nextAt[k] = find(n, in: buf, from: at) }
                        if let i = nextAt[k], best.map({ i < $0 }) ?? true { best = i }
                    }
                    guard let hit = best else { break }
                    let r = lineBounds(hit)
                    line += countNewlines(buf, counted..<r.lowerBound)
                    counted = r.lowerBound
                    emit(r, line)
                    at = r.upperBound + 1
                    if Date() > deadline { break }
                }
                return out
            }
            // Any other expression: a megabyte at a time, cut at line ends; lines are examined one by one
            // only in a piece the expression matches somewhere.
            var start = 0, line = 1
            while start < buf.count, out.count < options.perFile {
                var end = min(buf.count, start + (1 << 20))
                while end < buf.count, buf[end - 1] != 0x0A { end += 1 }
                let piece = String(decoding: UnsafeRawBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
                if pieceRe.firstMatch(in: piece, range: NSRange(piece.startIndex..., in: piece)) != nil {
                    var at = start, n = line
                    while at < end, out.count < options.perFile {
                        let r = lineBounds(at)
                        emit(r.lowerBound..<min(r.upperBound, end), n)
                        at = r.upperBound + 1
                        n += 1
                    }
                }
                line += countNewlines(buf, start..<end)
                start = end
                if Date() > deadline { break }
            }
            return out
        }
    }

    // MARK: Reading part of a large file

    /// Lines `start ..< start + limit` (1-based) of a file too large to load whole, read from a mapping:
    /// only the bytes up to the last line wanted are touched. `more` says whether the file goes on.
    public static func lines(of url: URL, from start: Int, limit: Int, maxLine: Int = 2000) -> (lines: [String], more: Bool)? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) -> (lines: [String], more: Bool)? in
            guard let base = buf.baseAddress else { return ([], false) }
            if memchr(base, 0, min(buf.count, 4096)) != nil { return nil }   // not text
            var at = 0, line = 1
            var out: [String] = []
            while at < buf.count, out.count < limit {
                let end = memchr(base + at, 0x0A, buf.count - at).map { base.distance(to: UnsafeRawPointer($0)) } ?? buf.count
                if line >= start {
                    var text = String(decoding: UnsafeRawBufferPointer(rebasing: buf[at..<min(end, at + maxLine * 4)]), as: UTF8.self)
                    if text.hasSuffix("\r") { text.removeLast() }
                    out.append(text.truncated(maxLine, marker: "…"))
                }
                line += 1
                at = end + 1
            }
            return (out, at < buf.count)
        }
    }

    // MARK: Glob

    /// The folder a glob can only match inside (`benchmark/*.tsv` → `benchmark`), and how deep it can
    /// reach below it (nil when it has `**`).
    static func scope(of pattern: String) -> (prefix: String, depth: Int?) {
        let parts = pattern.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var fixed: [String] = []
        for p in parts.dropLast() {
            if p.contains(where: { "*?{}[]".contains($0) }) { break }
            fixed.append(p)
        }
        let rest = parts.dropFirst(fixed.count)
        return (fixed.joined(separator: "/"), pattern.contains("**") ? nil : max(1, rest.count))
    }
}
