import Foundation

/// The research panels' data (docs/SERVE_PROTOCOL.md, "Panels"): what the SwiftUI panels read from the
/// open task's services — the trace from the audit log, library, notebook, learning proposals, changed
/// files and their diffs, the private history, jobs, figures, and the workspace's files.
extension ServeServer {
    func panelsDispatch(_ method: String, _ p: JSON) async throws -> JSON? {
        switch method {
        case "panels.trace":
            // Incremental: the front end passes the offset it got last time and appends what is new.
            let s = try current(p).bench.services
            let (entries, offset) = AuditLog.readNew(s.audit.url, from: UInt64(max(0, p["offset"]?.intValue ?? 0)), kinds: Trace.kinds)
            let iso = ISO8601DateFormatter()
            return ["offset": .int(Int(offset)), "events": .array(Trace.events(entries).map { e in
                ["id": .int(e.id), "at": .string(iso.string(from: e.at)), "actor": .string(e.actor), "kind": .string(e.kind),
                 "text": .string(e.text), "isError": .bool(e.isError), "category": .string(e.category.rawValue)]
            })]

        case "panels.library":
            let s = try current(p).bench.services
            return ["dir": .string(s.library.dir.path), "papers": Wire.value(s.library.records)]
        case "library.links":
            // Where the workspace's code cites a paper (`@cite key §3`); walks the files, so asked for separately.
            let s = try current(p).bench.services
            let ws = s.workspace, lib = s.library
            let links = await Task.detached { CodePaperLinker.scan(workspace: ws, library: lib) }.value
            return ["links": Wire.value(links)]

        case "panels.notebook":
            let s = try current(p).bench.services
            return ["path": .string(s.notebook.url.path), "text": .string((try? String(contentsOf: s.notebook.url, encoding: .utf8)) ?? "")]

        case "panels.learning":
            return ["proposals": Wire.value(Array(try current(p).bench.services.governor.proposals.reversed()))]
        case "learning.decide", "learning.revert":
            let s = try current(p).bench.services
            guard let id = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            let message = method == "learning.revert" ? s.governor.revert(id, services: s) : s.governor.decide(id, approve: p["approve"]?.boolValue == true, services: s)
            return ["message": .string(message), "proposals": Wire.value(Array(s.governor.proposals.reversed()))]

        case "panels.changes":
            let s = try current(p).bench.services
            return ["files": .array(s.changes.changedFiles.map { f in
                let d = s.changes.diff(f, workspace: s.workspace)
                return ["path": .string(Self.relative(f, s.workspace)), "added": .int(d.added), "removed": .int(d.removed), "isNewFile": .bool(d.isNewFile)]
            })]
        case "changes.diff":
            let s = try current(p).bench.services
            guard let path = p.str("path") else { throw RPCError(code: -32602, message: "path is required") }
            return ["diff": Wire.diff(s.changes.diff(Self.absolute(path, s.workspace), workspace: s.workspace))]
        case "changes.revert":
            let s = try current(p).bench.services
            guard let path = p.str("path") else { throw RPCError(code: -32602, message: "path is required") }
            let ok = s.changes.revert(Self.absolute(path, s.workspace))
            if ok { s.log("revert_file", actor: "user", ["path": .string(path)]) }
            return ["ok": .bool(ok), "diff": Wire.diff(s.changes.diff(Self.absolute(path, s.workspace), workspace: s.workspace))]

        case "panels.history":
            let s = try current(p).bench.services
            return ["commits": .array(await s.git.log(limit: 200).map { c in
                ["hash": .string(c.hash), "subject": .string(c.subject), "date": .string(c.date), "files": .int(c.files)]
            })]
        case "history.diffs":
            let s = try current(p).bench.services
            guard let hash = p.str("hash") else { throw RPCError(code: -32602, message: "hash is required") }
            return ["diffs": .array(await s.git.diffs(of: hash).map(Wire.diff))]
        case "history.restore":
            // The current state is committed first, so a restore can itself be undone.
            let s = try current(p).bench.services
            guard let hash = p.str("hash") else { throw RPCError(code: -32602, message: "hash is required") }
            _ = await s.git.snapshot(subject: "before restore to \(hash.prefix(10))", trailers: ["SieveSci-Task": s.taskId])
            let ok = await s.git.restore(hash)
            s.log("git_restore", actor: "user", ["commit": .string(hash), "ok": .bool(ok)])
            return ["ok": .bool(ok)]

        case "panels.jobs":
            let s = try current(p).bench.services
            return ["jobs": .array(s.jobs.all.map { j in
                ["id": .string(j.id), "label": .string(j.label), "running": .bool(j.running), "exitCode": j.exitCode.map { .int(Int($0)) } ?? .null,
                 "seconds": j.finished.map { .int(Int($0.timeIntervalSince(j.started))) } ?? .null, "logPath": .string(j.logPath),
                 "lines": .array(j.tail.map { .string($0) })]
            })]
        case "jobs.stop":
            guard let id = p.str("id") else { throw RPCError(code: -32602, message: "id is required") }
            return ["ok": .bool(try current(p).bench.services.jobs.stop(id))]

        case "panels.figures":
            // Figures any tool wrote (scripts, kernels), not only file edits; newest first.
            let s = try current(p).bench.services
            var seen = Set<String>(), out: [JSON] = []
            for r in s.ledger.all.reversed() {
                for path in r.filesWritten.keys where Self.isFigure(path) {
                    let u = path.hasPrefix("/") ? URL(fileURLWithPath: path) : s.workspace.appendingPathComponent(path)
                    if seen.insert(u.path).inserted, FileManager.default.fileExists(atPath: u.path) { out.append(.string(u.path)) }
                }
            }
            return ["figures": .array(out)]

        case "files.list":
            let (ws, _) = try target(p)
            let dir = p.str("path").map { Self.absoluteURL($0, ws) } ?? ws
            try Self.inside(dir, ws)
            let urls = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [])) ?? []
            let entries = urls.filter { !Self.skippedFiles.contains($0.lastPathComponent) }
                .map { ($0, (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true) }
                .sorted { ($0.1 ? 0 : 1, $0.0.lastPathComponent.lowercased()) < ($1.1 ? 0 : 1, $1.0.lastPathComponent.lowercased()) }
                .prefix(2000)
            return ["entries": .array(entries.map { u, isDir in
                ["name": .string(u.lastPathComponent), "path": .string(Self.relative(u.path, ws)), "isDir": .bool(isDir)]
            })]
        case "files.read":
            // A preview: text up to 400 kB, images and PDFs as data URLs up to 15 MB.
            let (ws, _) = try target(p)
            guard let path = p.str("path") else { throw RPCError(code: -32602, message: "path is required") }
            let url = Self.absoluteURL(path, ws)
            try Self.inside(url, ws)
            let size = ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            let ext = url.pathExtension.lowercased()
            let mime = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "svg": "image/svg+xml", "pdf": "application/pdf"][ext]
            if let mime {
                guard size <= 15_000_000, let d = try? Data(contentsOf: url) else { return ["kind": "binary", "size": .int(size)] }
                return ["kind": .string(ext == "pdf" ? "pdf" : "image"), "size": .int(size), "dataURL": .string("data:\(mime);base64," + d.base64EncodedString())]
            }
            guard let h = try? FileHandle(forReadingFrom: url) else { throw RPCError(code: -32000, message: "cannot read \(path)") }
            defer { try? h.close() }
            let d = (try? h.read(upToCount: 400_000)) ?? Data()
            guard let text = String(data: d, encoding: .utf8), !d.contains(0) else { return ["kind": "binary", "size": .int(size)] }
            return ["kind": "text", "size": .int(size), "text": .string(text), "truncated": .bool(size > d.count)]

        default:
            return nil
        }
    }

    static let skippedFiles: Set<String> = [".git", ".sievesci", ".build", "node_modules", "__pycache__", ".venv", "venv", ".DS_Store", ".ipynb_checkpoints"]

    static func isFigure(_ path: String) -> Bool {
        ["png", "jpg", "jpeg", "svg", "pdf", "tif", "tiff", "gif", "webp"].contains((path as NSString).pathExtension.lowercased())
    }

    static func relative(_ path: String, _ ws: URL) -> String {
        let root = ws.standardizedFileURL.path
        return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
    }

    static func absolute(_ path: String, _ ws: URL) -> String { absoluteURL(path, ws).path }

    static func absoluteURL(_ path: String, _ ws: URL) -> URL {
        (path.hasPrefix("/") || path.range(of: #"^[A-Za-z]:[\\/]"#, options: .regularExpression) != nil
            ? URL(fileURLWithPath: path) : ws.appendingPathComponent(path)).standardizedFileURL
    }

    /// Files and folders are read inside the workspace only.
    static func inside(_ url: URL, _ ws: URL) throws {
        let root = ws.standardizedFileURL.resolvingSymlinksInPath().path, p = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard p == root || p.hasPrefix(root + "/") else { throw RPCError(code: -32602, message: "outside the workspace") }
    }
}
