import Foundation
#if canImport(Security)
import Security
#endif
#if os(Windows)
import WinSDK
#endif

/// API keys in the platform's credential store, readable and writable by every front end:
/// - macOS: the Keychain, as generic passwords with service `app.sievesci.SieveSci` and the key's
///   reference as account (exactly what the SwiftUI app writes, so its keys are found as they are);
/// - Windows: Credential Manager, target `app.sievesci.SieveSci/<ref>`;
/// - elsewhere: `secrets.json` (mode 0600) next to the configuration.
/// Environment variables win everywhere (CI, power users). A configuration folder set with
/// `SIEVESCI_CONFIG_DIR` is a profile of its own (tests, a portable copy): its keys live in its
/// `secrets.json`, never in the system store.
public final class PlatformSecretStore: SecretStore, @unchecked Sendable {
    public static let service = "app.sievesci.SieveSci"
    public static let shared = PlatformSecretStore()

    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init() {}

    public func secret(for ref: String) -> String? {
        guard !ref.isEmpty else { return nil }
        if let v = EnvironmentSecretStore().secret(for: ref) { return v }
        if let hit = lock.withLock({ cache[ref] }) { return hit }
        let v = (Self.separateProfile ? Self.fileRead(ref) : Self.read(ref)).flatMap { $0.isEmpty ? nil : $0 }
        lock.withLock { cache[ref] = .some(v) }
        return v
    }

    /// Stores a key; an empty value removes it.
    public func set(_ value: String, for ref: String) throws {
        guard !ref.isEmpty else { return }
        if Self.separateProfile {
            if value.isEmpty { try Self.fileRemove(ref) } else { try Self.fileWrite(value, for: ref) }
        } else {
            if value.isEmpty { try Self.remove(ref) } else { try Self.write(value, for: ref) }
        }
        lock.withLock { cache[ref] = .some(value.isEmpty ? nil : value) }
    }

    public func has(_ ref: String) -> Bool { secret(for: ref) != nil }

    public struct Failure: Error, CustomStringConvertible { public var description: String }

    static var separateProfile: Bool { !(ProcessInfo.processInfo.environment["SIEVESCI_CONFIG_DIR"] ?? "").isEmpty }

    // MARK: secrets.json (other platforms, separate profiles)

    private static var file: URL { AppConfig.directory.appendingPathComponent("secrets.json") }

    private static func loadFile() -> [String: String] {
        guard let d = try? Data(contentsOf: file), let j = try? JSONDecoder().decode([String: String].self, from: d) else { return [:] }
        return j
    }

    private static func storeFile(_ all: [String: String]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(all).writeReliably(to: file)
        #if !os(Windows)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #endif
    }

    static func fileRead(_ ref: String) -> String? { loadFile()[ref] }
    static func fileWrite(_ value: String, for ref: String) throws { var a = loadFile(); a[ref] = value; try storeFile(a) }
    static func fileRemove(_ ref: String) throws { var a = loadFile(); a[ref] = nil; try storeFile(a) }

    // MARK: macOS

    #if canImport(Security) && !os(iOS)
    private static func query(_ ref: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: ref,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    static func read(_ ref: String) -> String? {
        var q = query(ref)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func write(_ value: String, for ref: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(ref) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query(ref)
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let s = SecItemAdd(add as CFDictionary, nil)
            guard s == errSecSuccess else { throw Failure(description: "Keychain error \(s)") }
        } else if status != errSecSuccess {
            throw Failure(description: "Keychain error \(status)")
        }
    }

    static func remove(_ ref: String) throws {
        let s = SecItemDelete(query(ref) as CFDictionary)
        guard s == errSecSuccess || s == errSecItemNotFound else { throw Failure(description: "Keychain error \(s)") }
    }

    // MARK: Windows

    #elseif os(Windows)
    private static func target(_ ref: String) -> String { "\(service)/\(ref)" }

    static func read(_ ref: String) -> String? {
        var cred: PCREDENTIALW?
        let ok = target(ref).withCString(encodedAs: UTF16.self) { CredReadW($0, DWORD(CRED_TYPE_GENERIC), 0, &cred) }
        guard ok, let c = cred else { return nil }
        defer { CredFree(c) }
        let size = Int(c.pointee.CredentialBlobSize)
        guard size > 0, let blob = c.pointee.CredentialBlob else { return nil }
        return String(decoding: UnsafeBufferPointer(start: blob, count: size), as: UTF8.self)
    }

    static func write(_ value: String, for ref: String) throws {
        var bytes = Array(value.utf8)
        let ok: Bool = target(ref).withCString(encodedAs: UTF16.self) { name in
            "SieveSci".withCString(encodedAs: UTF16.self) { user in
                bytes.withUnsafeMutableBufferPointer { buf in
                    var c = CREDENTIALW()
                    c.Type = DWORD(CRED_TYPE_GENERIC)
                    c.TargetName = UnsafeMutablePointer(mutating: name)
                    c.UserName = UnsafeMutablePointer(mutating: user)
                    c.CredentialBlobSize = DWORD(buf.count)
                    c.CredentialBlob = buf.baseAddress
                    c.Persist = DWORD(CRED_PERSIST_LOCAL_MACHINE)
                    return CredWriteW(&c, 0)
                }
            }
        }
        guard ok else { throw Failure(description: "Credential Manager error \(GetLastError())") }
    }

    static func remove(_ ref: String) throws {
        let ok = target(ref).withCString(encodedAs: UTF16.self) { CredDeleteW($0, DWORD(CRED_TYPE_GENERIC), 0) }
        if !ok, GetLastError() != DWORD(ERROR_NOT_FOUND) { throw Failure(description: "Credential Manager error \(GetLastError())") }
    }

    // MARK: Elsewhere

    #else
    static func read(_ ref: String) -> String? { fileRead(ref) }
    static func write(_ value: String, for ref: String) throws { try fileWrite(value, for: ref) }
    static func remove(_ ref: String) throws { try fileRemove(ref) }
    #endif
}
