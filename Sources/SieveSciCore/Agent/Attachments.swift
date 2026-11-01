import Foundation

/// Things the user attaches in the chat box (button, drag-and-drop, paste).
public enum Attachment: Sendable, Equatable {
    case file(URL)
    case githubRepo(URL)

    /// GitHub repository URLs in pasted text are treated as repo attachments.
    public static func githubLinks(in text: String) -> [URL] {
        Grounding.matches(#"https://github\.com/[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+(?:/tree/[A-Za-z0-9_.\-/]+)?"#, in: text)
            .compactMap { URL(string: $0.replacingOccurrences(of: ".git", with: "")) }
    }
}

public enum AttachmentBuilder {
    static let textExtensions: Set<String> = ["txt", "md", "py", "r", "R", "jl", "sh", "json", "yaml", "yml", "toml", "csv", "tsv", "fasta", "fa", "fastq",
                                              "gb", "gbk", "pdb", "cif", "sdf", "mol2", "smi", "xyz", "vcf", "bed", "gff", "gtf", "tex", "bib", "swift", "c", "cpp", "ipynb"]

    /// Converts attachments into message blocks. Large data never goes into the prompt: it is copied
    /// into the task's inputs/ folder and referenced by path (prompt size and cache stay bounded).
    public static func blocks(for attachments: [Attachment], services: SessionServices) async -> [ContentBlock] {
        var out: [ContentBlock] = []
        let inputs = services.workspace.appendingPathComponent("inputs")
        for a in attachments {
            switch a {
            case .file(let url):
                let ext = url.pathExtension.lowercased()
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                var local = url
                if !url.standardizedFileURL.path.hasPrefix(services.workspace.path) {
                    try? FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
                    local = inputs.appendingPathComponent(url.lastPathComponent)
                    try? FileManager.default.removeItem(at: local)
                    try? FileManager.default.copyItem(at: url, to: local)
                }
                let sha = Hashing.sha256OfFile(local) ?? ""
                services.log("attachment", actor: "user", ["path": .string(local.path), "sha256": .string(sha), "bytes": .int(size)])
                if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext), size < 5_000_000, let d = FileManager.default.contents(atPath: local.path) {
                    out.append(.image(ImageBlock(mediaType: ext == "jpg" ? "image/jpeg" : "image/\(ext)", base64: d.base64EncodedString())))
                    out.append(.text("[attached image: \(local.path)]"))
                } else if ext == "pdf" {
                    let text = LiteratureLibrary.extractText(local) ?? ""
                    out.append(.text("<attachment path=\"\(local.path)\" type=\"pdf\" sha256=\"\(sha.prefix(16))\">\n\(text.truncated(30_000))\n</attachment>"))
                } else if textExtensions.contains(ext), size < 60_000, let t = try? String(contentsOf: local, encoding: .utf8) {
                    out.append(.text("<attachment path=\"\(local.path)\" sha256=\"\(sha.prefix(16))\">\n\(t)\n</attachment>"))
                } else {
                    out.append(.text("<attachment path=\"\(local.path)\" bytes=\"\(size)\" sha256=\"\(sha.prefix(16))\">Large or binary file — inspect it with tools (python/bash), do not assume its contents.</attachment>"))
                }
            case .githubRepo(let url):
                out.append(.text(await cloneRepo(url, services: services)))
            }
        }
        return out
    }

    /// Shallow-clones a GitHub repo into the task and summarizes it (README head, file tree, CITATION.cff).
    static func cloneRepo(_ url: URL, services: SessionServices) async -> String {
        let parts = url.path.split(separator: "/")
        guard parts.count >= 2 else { return "[invalid GitHub URL \(url)]" }
        let name = "\(parts[0])__\(parts[1])"
        let dest = services.taskDir.appendingPathComponent("repos/\(name)")
        if !FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            let r = try? await ProcessRunner.run("git", ["clone", "--depth", "1", "https://github.com/\(parts[0])/\(parts[1]).git", dest.path], timeout: 600)
            if r?.exitCode != 0 { return "[could not clone \(url): \(r?.stderr.truncated(300) ?? "git not available")]" }
        }
        let commit = (try? await ProcessRunner.run("git", ["-C", dest.path, "rev-parse", "HEAD"], timeout: 30))?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        services.log("attachment", actor: "user", ["repo": .string(url.absoluteString), "path": .string(dest.path), "commit": .string(commit)])
        var tree: [String] = []
        if let en = FileManager.default.enumerator(at: dest, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for case let u as URL in en {
                if en.level > 2 { en.skipDescendants(); continue }
                tree.append(String(u.path.dropFirst(dest.path.count + 1)))
                if tree.count >= 150 { break }
            }
        }
        let readme = ["README.md", "README.rst", "README.txt", "README"].lazy.compactMap { try? String(contentsOf: dest.appendingPathComponent($0), encoding: .utf8) }.first ?? ""
        var citation = ""
        if let cff = try? String(contentsOf: dest.appendingPathComponent("CITATION.cff"), encoding: .utf8) {
            citation = "\nCITATION.cff:\n\(cff.truncated(2000))"
            if let doi = Grounding.matches(Grounding.doiPattern, in: cff).first {
                citation += "\n(The paper DOI \(doi) can be added to the library with paper_fetch.)"
            }
        }
        return """
        <repository url="\(url)" commit="\(commit)" local="\(dest.path)">
        Files (depth ≤ 3):
        \(tree.sorted().joined(separator: "\n"))

        README (head):
        \(readme.truncated(6000))\(citation)
        </repository>
        """
    }
}
