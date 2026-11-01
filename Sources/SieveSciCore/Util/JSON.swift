import Crypto
import Foundation
@_exported import enum MCP.Value

/// SieveSci uses the MCP SDK's `Value` as its universal JSON type, so MCP tool schemas and results
/// flow through the agent without conversion.
public typealias JSON = Value

public enum JSONCodec {
    /// Canonical encoding: sorted keys, no whitespace, no escaped slashes. Everything that reaches a
    /// provider's prompt prefix is serialized through here, because a reordered key silently breaks
    /// prefix caching on every vendor (Anthropic, OpenAI, Gemini, DeepSeek and GLM are all prefix-match).
    public static func canonicalData(_ value: JSON) -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? enc.encode(value)) ?? Data("null".utf8)
    }

    public static func canonicalString(_ value: JSON) -> String {
        String(decoding: canonicalData(value), as: UTF8.self)
    }

    public static func pretty(_ value: JSON) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
        return (try? enc.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    /// `Value.init(from:)` runs a data-URL regex on every string it decodes, which made reopening a task
    /// with a 35 MB audit log freeze the window for seconds. Foundation's parser plus a `data:` prefix
    /// check gives the same values at a fraction of the cost.
    public static func parse(_ data: Data) throws -> JSON {
        #if canImport(Darwin)
        return value(try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]))
        #else
        return try JSONDecoder().decode(JSON.self, from: data)
        #endif
    }

    #if canImport(Darwin)
    static func value(_ o: Any) -> JSON {
        switch o {
        case let s as String:
            if s.hasPrefix("data:"), Data.isDataURL(string: s), let (mime, d) = Data.parseDataURL(s) { return .data(mimeType: mime, d) }
            return .string(s)
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            let t = String(cString: n.objCType)
            guard t == "d" || t == "f" else { return .int(n.intValue) }
            // Like `Value`'s decoder, an integral literal such as 2.0 becomes `.int`.
            let d = n.doubleValue
            return d.rounded() == d && abs(d) < 9.0e15 ? .int(Int(d)) : .double(d)
        case let a as [Any]: return .array(a.map(value))
        case let m as [String: Any]: return .object(m.mapValues(value))
        default: return .null
        }
    }
    #endif

    public static func parse(_ string: String) throws -> JSON {
        try parse(Data(string.utf8))
    }

    /// Encodes any Codable value canonically (used by the audit log so entry hashes are reproducible).
    public static func canonicalData<T: Encodable>(encodable: T) throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(encodable)
    }
}

extension Value {
    public subscript(key: String) -> Value? { objectValue?[key] }

    public subscript(index: Int) -> Value? {
        guard let a = arrayValue, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    /// Numbers arrive as `.int` or `.double` depending on their literal form; accept both.
    public var numberValue: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }

    public func setting(_ key: String, _ value: Value?) -> Value {
        guard case .object(var o) = self else { return self }
        o[key] = value
        return .object(o)
    }

    public var canonical: String { JSONCodec.canonicalString(self) }
}

public enum Hashing {
    public static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func sha256Hex(_ string: String) -> String { sha256Hex(Data(string.utf8)) }

    /// Streams a file through SHA-256 in 1 MiB chunks, so multi-GB sequencing or imaging files can be
    /// fingerprinted for the provenance log without loading them into memory.
    public static func sha256OfFile(_ url: URL) -> String? {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? fh.close() }
        var hasher = SHA256()
        while true {
            let chunk = fh.readSome(1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

extension String {
    /// Short stable fingerprint (first 16 hex chars of SHA-256). Swift's `hashValue` is seeded per
    /// process and must never be used for cache keys or prefix fingerprints.
    public var stableHash: String { String(Hashing.sha256Hex(self).prefix(16)) }

    func truncated(_ max: Int, marker: String = "\n… [truncated]") -> String {
        count <= max ? self : String(prefix(max)) + marker
    }
}
