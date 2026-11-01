import Foundation
import KeychainAccess
import SieveSciCore

/// Keychain-backed secret store (falls back to environment variables for CI and power users).
struct KeychainSecretStore: SecretStore {
    static let keychain = Keychain(service: "app.sievesci.SieveSci").synchronizable(false)

    /// Keychain reads are slow and must not run on the main thread for every redraw (views ask whether
    /// each provider has a key), so each reference is read once and cached until it is set again.
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String?] = [:]

    func secret(for ref: String) -> String? {
        guard !ref.isEmpty else { return nil }
        if let hit = Self.cacheLock.withLock({ Self.cache[ref] }) { return hit ?? EnvironmentSecretStore().secret(for: ref) }
        let v = (try? Self.keychain.get(ref)).flatMap { $0.isEmpty ? nil : $0 }
        Self.cacheLock.withLock { Self.cache[ref] = .some(v) }
        return v ?? EnvironmentSecretStore().secret(for: ref)
    }

    static func set(_ value: String, for ref: String) {
        if value.isEmpty { try? keychain.remove(ref) } else { try? keychain.set(value, key: ref) }
        cacheLock.withLock { cache[ref] = .some(value.isEmpty ? nil : value) }
    }

    static func has(_ ref: String) -> Bool { KeychainSecretStore().secret(for: ref) != nil }
}
