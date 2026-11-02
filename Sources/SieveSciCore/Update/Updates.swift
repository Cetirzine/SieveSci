import Crypto
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A published SieveSci release, as GitHub's "latest release" API describes it.
public struct AppRelease: Equatable, Sendable {
    public struct Asset: Equatable, Sendable {
        public let name: String
        public let url: URL
        public let size: Int
        /// Lower-case hex SHA-256 that GitHub computed on upload (nil for assets uploaded before mid-2025).
        public let sha256: String?
    }

    public let version: String
    public let tag: String
    public let title: String
    public let notes: String
    public let page: URL
    public let asset: Asset?
}

/// Release checks against GitHub (`Cetirzine/SieveSci`). Only the lookup, version order and checksum live
/// here; downloading, unpacking and replacing the app bundle are the app's job.
public enum Updates {
    public static let repository = "Cetirzine/SieveSci"

    /// The release feed. SIEVESCI_UPDATE_FEED points it somewhere else (a file:// JSON in the same shape
    /// works too), for testing an update without publishing one.
    public static var feed: URL {
        if let s = ProcessInfo.processInfo.environment["SIEVESCI_UPDATE_FEED"], let u = URL(string: s) { return u }
        return URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    public enum Failure: Error, LocalizedError {
        case http(Int)
        case malformed
        case checksum(expected: String, actual: String)
        case size(expected: Int, actual: Int)

        public var errorDescription: String? {
            switch self {
            case .http(404): return L("No published release was found.")
            case .http(403), .http(429): return L("GitHub is rate-limiting update checks; try again later.")
            case .http(let code): return L("GitHub answered HTTP") + " \(code)."
            case .malformed: return L("The release information could not be read.")
            case .checksum(let e, let a): return L("The download is corrupt (checksum mismatch).") + " SHA-256 \(a.prefix(12))… ≠ \(e.prefix(12))…"
            case .size(let e, let a): return L("The download is incomplete.") + " \(a) / \(e) bytes"
            }
        }
    }

    public static func latest(session: URLSession = .shared) async throws -> AppRelease {
        var req = URLRequest(url: feed, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("SieveSci/\(SieveSci.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw Failure.http(http.statusCode) }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> AppRelease {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let page = (j["html_url"] as? String).flatMap(URL.init(string:)) else { throw Failure.malformed }
        let assets: [AppRelease.Asset] = (j["assets"] as? [[String: Any]] ?? []).compactMap { a in
            guard let name = a["name"] as? String,
                  let url = (a["browser_download_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            let digest = (a["digest"] as? String).flatMap { $0.hasPrefix("sha256:") ? String($0.dropFirst(7)).lowercased() : nil }
            return .init(name: name, url: url, size: a["size"] as? Int ?? 0, sha256: digest)
        }
        return AppRelease(version: normalized(tag), tag: tag, title: j["name"] as? String ?? tag,
                          notes: j["body"] as? String ?? "", page: page, asset: pick(assets))
    }

    /// The installable asset: the app's disk image, else its zip.
    static func pick(_ assets: [AppRelease.Asset]) -> AppRelease.Asset? {
        let ours = assets.filter { $0.name.lowercased().hasPrefix("sievesci") }
        return ours.first { $0.name.lowercased().hasSuffix(".dmg") } ?? ours.first { $0.name.lowercased().hasSuffix(".zip") }
    }

    /// "v0.2.0" → "0.2.0".
    public static func normalized(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    /// Numeric comparison of dotted versions ("0.10.0" > "0.9.1"); a pre-release suffix ("-beta.1") sorts
    /// before the plain version.
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        func split(_ v: String) -> ([Int], Bool) {
            let parts = normalized(v).split(separator: "-", maxSplits: 1)
            let nums = (parts.first ?? "").split(separator: ".").map { Int($0) ?? 0 }
            return (nums, parts.count > 1)
        }
        let (a, aPre) = split(candidate), (b, bPre) = split(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return bPre && !aPre
    }

    /// Checks a downloaded asset against the size and SHA-256 GitHub published for it.
    public static func verify(_ file: URL, against asset: AppRelease.Asset) throws {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? nil
        if asset.size > 0, let size, size != asset.size { throw Failure.size(expected: asset.size, actual: size) }
        guard let expected = asset.sha256 else { return }
        let actual = try sha256(of: file)
        if actual != expected { throw Failure.checksum(expected: expected, actual: actual) }
    }

    public static func sha256(of file: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: file)
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
