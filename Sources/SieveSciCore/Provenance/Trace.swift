import Foundation

/// One receipt's traceability chain: the call, its audit entry, output hash, files and code state.
public struct TraceLink: Sendable {
    public var receipt: String
    public var tool: String
    public var agent: String
    public var time: Date
    public var auditSeq: Int
    public var auditHash: String
    public var input: JSON
    public var outputSHA256: String
    public var outputExcerpt: String
    public var filesWritten: [String: String]
    public var success: Bool
    public var commit: String?
}

/// Everything the audit log says about a task, indexed for `/trace` and report export.
public struct ProvenanceTrace: Sendable {
    public var links: [String: TraceLink]
    public var commits: [(seq: Int, hash: String, subject: String)]
    public var verifications: [(claim: String, verdict: String, receipts: [String])]
    public var reviews: [(kind: String, verdict: String, seq: Int)]
    public var headHash: String
    public var entries: Int
    public var chainIntact: Bool

    public static func build(auditURL: URL) -> ProvenanceTrace {
        let entries = (try? AuditLog.read(auditURL)) ?? []
        var links: [String: TraceLink] = [:]
        var commits: [(seq: Int, hash: String, subject: String)] = []
        var verifications: [(claim: String, verdict: String, receipts: [String])] = []
        var reviews: [(kind: String, verdict: String, seq: Int)] = []
        for e in entries {
            let d = e.data
            switch e.kind {
            case "tool_call":
                guard let r = d.str("receipt") else { continue }
                links[r] = TraceLink(receipt: r, tool: d.str("tool") ?? "", agent: d.str("agent") ?? e.actor, time: e.time,
                                     auditSeq: e.seq, auditHash: e.hash, input: d["input"] ?? .null,
                                     outputSHA256: d.str("output_sha256") ?? "", outputExcerpt: d.str("output_excerpt") ?? "",
                                     filesWritten: (d["files_written"]?.objectValue ?? [:]).compactMapValues(\.stringValue),
                                     success: d.bool("success") == true, commit: nil)
            case "git_commit":
                commits.append((e.seq, d.str("commit") ?? "", d.str("subject") ?? ""))
            case "verification":
                verifications.append((d.str("claim") ?? "", d.str("verdict") ?? "", (d["receipts"]?.arrayValue ?? []).compactMap(\.stringValue)))
            case "supervisor_review":
                reviews.append((d.str("kind") ?? "", d.str("verdict") ?? "", e.seq))
            default: break
            }
        }
        // The code state behind a receipt is the first shadow commit after it.
        for (k, l) in links {
            links[k]?.commit = commits.first { $0.seq > l.auditSeq }?.hash
        }
        // `verify` returns the first broken entry, nil when the whole chain checks out.
        let intact: Bool = { do { return try AuditLog.verify(auditURL) == nil } catch { return false } }()
        return ProvenanceTrace(links: links, commits: commits, verifications: verifications, reviews: reviews,
                               headHash: entries.last?.hash ?? "", entries: entries.count, chainIntact: intact)
    }

    /// `/trace r12`: the chain from code to output to files, commit and audit entry.
    public func describe(_ receipt: String) -> String {
        guard let l = links[receipt] else { return L10n.s("No receipt %@ in this task's audit log.", receipt) }
        let code = l.input.str("code") ?? l.input.str("command") ?? l.input.canonical
        var s = [
            "\(l.receipt) · " + L10n.s("%@ by %@", l.tool, L(l.agent)) + " · \(ISO8601DateFormatter().string(from: l.time)) · " + L(l.success ? "succeeded" : "FAILED"),
            L10n.s("audit §%@ (hash %@…)", String(l.auditSeq), String(l.auditHash.prefix(16))) + ", " + L(chainIntact ? "chain intact" : "⚠ CHAIN BROKEN"),
            "output sha256 \(l.outputSHA256.prefix(16))…",
        ].joined(separator: "\n")
        if !l.filesWritten.isEmpty { s += "\n" + L("files:") + " " + l.filesWritten.map { "\($0.key) (\($0.value.prefix(12)))" }.joined(separator: ", ") }
        if let c = l.commit { s += "\n" + L10n.s("code state: shadow commit %@", String(c.prefix(12))) }
        s += "\n--- " + L("executed") + " ---\n\(code.truncated(3000))\n--- " + L("output (excerpt)") + " ---\n\(l.outputExcerpt.truncated(1500))"
        return s
    }
}

/// `/report export`: the report with a footnote per cited receipt and a provenance appendix
/// (claims, reviews, unreviewed steps, disagreements, environment, code history); DOCX/PDF via pandoc.
public enum ReportExporter {
    public static func export(report: URL, services: SessionServices, formats: [String] = ["md", "docx"]) async -> [String] {
        guard var text = try? String(contentsOf: report, encoding: .utf8) else { return [L10n.s("Report not found: %@", report.path)] }
        let trace = ProvenanceTrace.build(auditURL: services.audit.url)
        var notes: [String] = []
        var used: [String] = []
        for r in Grounding.matches(#"[\(\[](r\d+)[\)\]]"#, in: text, group: 1) where !used.contains(r) {
            guard let l = trace.links[r] else { continue }
            used.append(r)
            text = text.replacingOccurrences(of: "[\(r)]", with: "[^\(r)]").replacingOccurrences(of: "(\(r))", with: "[^\(r)]")
            let what = l.input.str("code") ?? l.input.str("command") ?? l.tool
            notes.append("[^\(r)]: \(l.tool) `\((what.split(separator: "\n").first.map { String($0) } ?? what).truncated(80))` · output sha256 \(l.outputSHA256.prefix(12)) · audit §\(l.auditSeq)\(l.commit.map { " · commit \($0.prefix(10))" } ?? "")")
        }
        let claims = services.claims.snapshot
        var appendix = "\n\n## " + L("Provenance") + "\n\n"
        appendix += L10n.s("Task `%@` · audit log `%@` · %@ entries · head hash `%@…` · chain %@.", services.taskId, services.audit.url.lastPathComponent,
                           String(trace.entries), String(trace.headHash.prefix(24)), trace.chainIntact ? L("verified intact") : "**" + L("BROKEN") + "**") + "\n\n"
        if !claims.isEmpty {
            appendix += "### " + L("Claims and independent verification") + "\n\n| " + L("Claim") + " | " + L("Status") + " | " + L("Verifier receipts") + " |\n|---|---|---|\n"
            for c in claims { appendix += "| \(c.id): \(c.statement.replacingOccurrences(of: "|", with: "/")) | \(L(c.status.rawValue)) | \(c.verifierReceipts.joined(separator: ", ")) |\n" }
            appendix += "\n"
        }
        if !trace.reviews.isEmpty {
            appendix += "### " + L("Checker reviews") + "\n\n" + trace.reviews.map { "- \(L($0.kind)): **\(L($0.verdict))** (audit §\($0.seq))" }.joined(separator: "\n") + "\n\n"
        }
        let missing = services.refusals.unreviewed
        if !missing.isEmpty {
            appendix += "### " + L("Reviews that could not be obtained") + "\n\n" + L("These steps have **no independent review**; their results are reported as unreviewed.") + "\n\n"
                + missing.map { "- \(L($0.role)) · \($0.purpose) · \($0.kind.rawValue): \($0.detail.truncated(160).replacingOccurrences(of: "\n", with: " "))" }.joined(separator: "\n") + "\n\n"
        }
        let contested = services.deliberation.contested
        if !contested.isEmpty {
            appendix += "### " + L("Unresolved disagreements between agents") + "\n\n"
                + contested.map { "- \($0.thread) (\(L($0.kind))): \($0.issue.truncated(200)) — \($0.reason.truncated(160))" }.joined(separator: "\n") + "\n\n"
        }
        if let env = try? String(contentsOf: services.taskDir.appendingPathComponent("environment.txt"), encoding: .utf8) {
            appendix += "### " + L("Computational environment") + "\n\n```\n\(env.truncated(4000))\n```\n\n"
        }
        if !trace.commits.isEmpty {
            appendix += "### " + L("Code history (shadow git)") + "\n\n" + trace.commits.suffix(30).map { "- `\($0.hash.prefix(10))` \($0.subject)" }.joined(separator: "\n") + "\n\n"
        }
        let bib = services.library.dir.appendingPathComponent("references.bib")
        var out = text + "\n" + notes.joined(separator: "\n") + appendix + "\n## " + L("References") + "\n"
        if !FileManager.default.fileExists(atPath: bib.path) { out += "\n(" + L("no library entries") + ")\n" }
        let base = report.deletingPathExtension().lastPathComponent + "-traced"
        let md = report.deletingLastPathComponent().appendingPathComponent(base + ".md")
        try? out.writeReliably(to: md)
        var results = [L10n.s("Markdown with provenance: %@ (%@ receipts traced)", md.path, String(used.count))]
        services.log("report_export", actor: "host", ["report": .string(report.path), "sha256": .string(Hashing.sha256Hex(out)),
                                                      "receipts": .array(used.map { .string($0) })])
        guard ProcessRunner.which("pandoc") != nil else {
            return results + [L("Install pandoc (brew install pandoc) for DOCX/PDF export with a formatted bibliography.")]
        }
        for f in formats where f != "md" {
            let dest = md.deletingPathExtension().appendingPathExtension(f)
            var args = [md.path, "-o", dest.path, "--citeproc"]
            if FileManager.default.fileExists(atPath: bib.path) { args += ["--bibliography", bib.path] }
            if let r = try? await ProcessRunner.run("pandoc", args, cwd: report.deletingLastPathComponent(), timeout: 300) {
                results.append(r.exitCode == 0 ? "\(f.uppercased()): \(dest.path)" : L10n.s("%@ failed: %@", f.uppercased(), r.stderr.truncated(200)))
            }
        }
        return results
    }
}

/// Reproducibility: records the computational environment at session start (Python / R versions
/// and installed packages) into `environment.txt`, hashed into the audit log.
public enum EnvironmentSnapshot {
    public static func capture(services: SessionServices) async {
        var parts: [String] = ["SieveSci \(SieveSci.version)", "OS: \(ProcessInfo.processInfo.operatingSystemVersionString)"]
        if let py = try? await ProcessRunner.run(Platform.python, ["-c", "import sys,platform;print('Python',sys.version.split()[0],platform.platform())"], timeout: 30), py.exitCode == 0 {
            parts.append(py.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            if let pip = try? await ProcessRunner.run(Platform.python, ["-m", "pip", "freeze", "--disable-pip-version-check"], timeout: 60), pip.exitCode == 0 {
                parts.append("pip packages:\n" + pip.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        if ProcessRunner.which("Rscript") != nil,
           let r = try? await ProcessRunner.run("Rscript", ["-e", "cat(R.version.string,'\\n');ip<-installed.packages()[,c('Package','Version')];cat(paste(ip[,1],ip[,2]),sep='\\n')"], timeout: 60),
           r.exitCode == 0 {
            parts.append(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if let conda = ProcessRunner.loginEnvironment["CONDA_DEFAULT_ENV"] { parts.append("conda env: \(conda)") }
        let text = parts.joined(separator: "\n\n")
        let url = services.taskDir.appendingPathComponent("environment.txt")
        try? text.writeReliably(to: url)
        services.log("environment", actor: "host", ["sha256": .string(Hashing.sha256Hex(text)),
                                                    "summary": .string(parts.prefix(3).joined(separator: " | "))])
    }
}

/// `/export ipynb`: the Python this task executed, as a Jupyter notebook (code cells in order, with
/// the recorded output excerpt and the receipt in each cell's metadata).
public enum NotebookExport {
    public static func ipynb(services: SessionServices) -> URL? {
        let entries = (try? AuditLog.read(services.audit.url)) ?? []
        var cells: [JSON] = [[
            "cell_type": "markdown", "metadata": [:],
            "source": .array(["# SieveSci task \(services.taskId)\n", "\n",
                              "Cells exported from the provenance log; outputs are recorded excerpts. Re-run to reproduce.\n"].map { .string($0) }),
        ]]
        for e in entries where e.kind == "tool_call" && e.data.str("tool") == "python" && e.data.bool("success") == true {
            guard let code = e.data["input"]?.str("code") else { continue }
            let receipt = e.data.str("receipt") ?? ""
            func lines(_ s: String) -> JSON {
                let parts = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                return .array(parts.enumerated().map { i, l in .string(i < parts.count - 1 ? l + "\n" : l) })
            }
            cells.append([
                "cell_type": "code", "execution_count": .null,
                "metadata": ["sievesci": ["receipt": .string(receipt), "audit_seq": .int(e.seq)]],
                "source": lines(code),
                "outputs": [["output_type": "stream", "name": "stdout", "text": lines(e.data.str("output_excerpt") ?? "")]],
            ])
        }
        guard cells.count > 1 else { return nil }
        let nb: JSON = [
            "cells": .array(cells),
            "metadata": ["kernelspec": ["name": "python3", "display_name": "Python 3", "language": "python"]],
            "nbformat": 4, "nbformat_minor": 5,
        ]
        let url = services.taskDir.appendingPathComponent("analysis.ipynb")
        guard (try? Data(nb.canonical.utf8).write(to: url, options: .atomic)) != nil else { return nil }
        return url
    }
}

/// Per-file changes made during a task: the original content (nil = the file did not exist) is kept
/// at the first edit, so the Changes panel can show a diff since the task started and revert a file.
public final class ChangeTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var originals: [String: String?] = [:]
    private var order: [String] = []

    public init() {}

    /// The file's current content (nil if it does not exist), read before an edit.
    public func before(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    /// Records the content before the first change to `path`; later changes keep that original.
    public func record(path: String, before: String?) {
        lock.lock(); defer { lock.unlock() }
        guard originals.index(forKey: path) == nil else { return }
        originals[path] = .some(before)
        order.append(path)
    }

    /// Diff of `path` since the task started.
    public func diff(_ path: String, workspace: URL) -> FileDiff {
        let orig: String?? = lock.withLock { originals[path] }
        let now = try? String(contentsOfFile: path, encoding: .utf8)
        let rel = path.hasPrefix(workspace.path + "/") ? String(path.dropFirst(workspace.path.count + 1)) : path
        return FileDiff.make(path: rel, old: orig ?? nil, new: now)
    }

    public var changedFiles: [String] {
        lock.lock(); defer { lock.unlock() }
        return order
    }

    /// Restores the file as it was when the task started (deleting it if it did not exist then).
    public func revert(_ path: String) -> Bool {
        let orig: String?? = lock.withLock { originals[path] }
        guard let o = orig else { return false }
        if let content = o {
            return (try? content.write(toFile: path, atomically: true, encoding: .utf8)) != nil
        }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }
}
