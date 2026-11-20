import Foundation
import Security
import Synchronization

/// Small string store for secrets (the session token, the device id). The live one is the Keychain; tests use
/// `InMemorySecureStore`.
public protocol SecureStore: Sendable {
    /// The stored value, nil when absent. Throws when the store cannot be read right now (e.g. before first unlock).
    func read(_ key: String) throws -> String?
    func write(_ key: String, value: String) throws
    /// Removes the value; absent is not an error.
    func delete(_ key: String) throws
}

public struct SecureStoreError: Error, Sendable, Equatable {
    public var status: OSStatus

    public init(status: OSStatus) { self.status = status }
}

/// Generic-password items in a shared Keychain access group so the share extension reads the same token.
/// Accessibility `AfterFirstUnlockThisDeviceOnly`: background work can read it while the device is locked, and it
/// never leaves the device or enters a backup.
public struct KeychainSecureStore: SecureStore {
    public let service: String
    /// Full access group including the team prefix (`<TEAMID>.app.sroka.shared`); nil uses the app's default group.
    public let accessGroup: String?

    public init(service: String, accessGroup: String?) {
        self.service = service
        self.accessGroup = accessGroup
    }

    private func query(_ key: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    public func read(_ key: String) throws -> String? {
        var query = query(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            return nil
        default:
            throw SecureStoreError(status: status)
        }
    }

    public func write(_ key: String, value: String) throws {
        let data = Data(value.utf8)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemUpdate(query(key) as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query(key)
            add.merge(attributes) { _, new in new }
            let added = SecItemAdd(add as CFDictionary, nil)
            guard added == errSecSuccess else { throw SecureStoreError(status: added) }
        default:
            throw SecureStoreError(status: status)
        }
    }

    public func delete(_ key: String) throws {
        let status = SecItemDelete(query(key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SecureStoreError(status: status) }
    }
}

/// Thread-safe dictionary store for tests and previews. `failing` makes every call throw (a locked device).
public final class InMemorySecureStore: SecureStore {
    private let values: Mutex<[String: String]>
    private let failure = Mutex<SecureStoreError?>(nil)

    public init(_ values: [String: String] = [:]) {
        self.values = Mutex(values)
    }

    public var snapshot: [String: String] { values.withLock { $0 } }

    /// While set, every call throws it.
    public func setFailure(_ error: SecureStoreError?) { failure.withLock { $0 = error } }

    private func check() throws {
        if let error = failure.withLock({ $0 }) { throw error }
    }

    public func read(_ key: String) throws -> String? {
        try check()
        return values.withLock { $0[key] }
    }

    public func write(_ key: String, value: String) throws {
        try check()
        values.withLock { $0[key] = value }
    }

    public func delete(_ key: String) throws {
        try check()
        values.withLock { $0[key] = nil }
    }
}
