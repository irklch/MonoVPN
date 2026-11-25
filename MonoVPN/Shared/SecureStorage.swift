import Foundation
import Security

/// Minimal Keychain wrapper shared by the app and the Packet Tunnel extension.
///
/// Items use `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the tunnel can be
/// (re)started by the system while the device is locked, and secrets never leave
/// the device through backups.
struct SecureStorage: Sendable {
    enum Failure: Error, Equatable {
        case unexpectedStatus(OSStatus)
    }

    private let service: String
    private let accessGroup: String?

    init(service: String = "com.irklch.monovpn", accessGroup: String? = AppIdentifiers.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    func data(for key: SecureStorageKey) throws -> Data? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw Failure.unexpectedStatus(status)
        }
    }

    func set(_ data: Data, for key: SecureStorageKey) throws {
        let query = baseQuery(for: key)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery.merge(attributes) { _, new in new }
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Failure.unexpectedStatus(addStatus) }
        default:
            throw Failure.unexpectedStatus(updateStatus)
        }
    }

    func remove(_ key: SecureStorageKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }

    func string(for key: SecureStorageKey) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    func set(_ string: String, for key: SecureStorageKey) throws {
        try set(Data(string.utf8), for: key)
    }

    private func baseQuery(for key: SecureStorageKey) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key.rawValue,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
