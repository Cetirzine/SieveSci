import Foundation

/// Host-issued record of one tool call. Adapted from Reasonix's evidence ledger idea: a model's
/// statement ("step done", "p = 0.003", "tests pass") is a *report*; a receipt is *host proof*.
/// Checkpoints and claims must cite receipt ids, and the host checks that the cited receipts
/// exist, succeeded, and actually contain the numbers being asserted.
public struct Receipt: Codable, Sendable, Identifiable, Equatable {
    public var id: String                 // "r12"
    public var tool: String
    public var argsSummary: String
    public var success: Bool
    public var exitCode: Int32?
    public var outputDigest: String       // sha256 of the full output
    public var outputExcerpt: String      // bounded text the supervisor and grounding checks read
    public var filesWritten: [String: String]   // path → sha256 after the call
    public var startedAt: Date
    public var duration: TimeInterval
    public var role: AgentRole
}

public final class EvidenceLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var receipts: [Receipt] = []
    private var counter = 0
    /// Full outputs kept in memory for grounding checks (bounded per receipt).
    private var outputs: [String: String] = [:]
    public static let excerptLimit = 4000
    public static let fullLimit = 200_000
    /// Where receipts persist (`<task>/state`); nil = in memory only.
    let dir: URL?
    /// Receipts whose stored output no longer matches its digest (edited on disk). Their output is
    /// not loaded, so it can neither ground a claim nor be read back as evidence.
    public private(set) var tamperedOutputs: [String] = []

    /// Loads the receipts already recorded for this task, so ids continue (r13 after r12) and
    /// receipts cited in a resumed transcript still resolve.
    public init(dir: URL? = nil) {
        self.dir = dir
        guard let dir else { return }
        receipts = StateFile.lines(Receipt.self, from: dir.appendingPathComponent("receipts.jsonl"))
        counter = receipts.compactMap { Int($0.id.dropFirst()) }.max() ?? 0
        for r in receipts {
            guard let o = try? String(contentsOf: outputURL(r.id), encoding: .utf8) else { continue }
            // Outputs longer than the stored bound cannot be re-hashed; shorter ones must match.
            if o.count < Self.fullLimit && Hashing.sha256Hex(o) != r.outputDigest { tamperedOutputs.append(r.id); continue }
            outputs[r.id] = o
        }
    }

    func outputURL(_ id: String) -> URL { dir!.appendingPathComponent("outputs/\(id).txt") }

    @discardableResult
    public func record(tool: String, args: JSON, output: ToolOutput, role: AgentRole, startedAt: Date, duration: TimeInterval) -> Receipt {
        lock.lock(); defer { lock.unlock() }
        counter += 1
        var files: [String: String] = [:]
        for p in output.filesWritten { files[p] = Hashing.sha256OfFile(URL(fileURLWithPath: p)) ?? "missing" }
        let r = Receipt(
            id: "r\(counter)", tool: tool, argsSummary: String(args.canonical.prefix(400)),
            success: !output.isError && (output.exitCode ?? 0) == 0, exitCode: output.exitCode,
            outputDigest: Hashing.sha256Hex(output.text), outputExcerpt: Self.excerpt(output.text),
            filesWritten: files, startedAt: startedAt, duration: duration, role: role)
        receipts.append(r)
        let stored = String(output.text.suffix(Self.fullLimit))
        outputs[r.id] = stored
        if let dir {
            // Output first: a receipt line on disk always has its output next to it.
            try? FileManager.default.createDirectory(at: dir.appendingPathComponent("outputs"), withIntermediateDirectories: true)
            try? stored.write(to: outputURL(r.id), atomically: true, encoding: .utf8)
            StateFile.append(line: r, to: dir.appendingPathComponent("receipts.jsonl"))
        }
        return r
    }

    static func excerpt(_ s: String) -> String {
        guard s.count > excerptLimit else { return s }
        return String(s.prefix(excerptLimit / 2)) + "\n…\n" + String(s.suffix(excerptLimit / 2))
    }

    public func receipt(_ id: String) -> Receipt? {
        lock.lock(); defer { lock.unlock() }
        return receipts.first { $0.id == id.trimmingCharacters(in: .whitespaces) }
    }

    public func output(_ id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return outputs[id]
    }

    public var all: [Receipt] { lock.lock(); defer { lock.unlock() }; return receipts }

    public func since(_ index: Int) -> [Receipt] {
        lock.lock(); defer { lock.unlock() }
        return index < receipts.count ? Array(receipts[index...]) : []
    }

    public var count: Int { lock.lock(); defer { lock.unlock() }; return receipts.count }

    /// Concatenated outputs (most recent first) — the evidence corpus for grounding checks.
    public func corpus(limit: Int = 2_000_000) -> String {
        lock.lock(); defer { lock.unlock() }
        var out = ""
        for r in receipts.reversed() {
            guard let o = outputs[r.id] else { continue }
            out += o + "\n"
            if out.count > limit { break }
        }
        return out
    }
}
