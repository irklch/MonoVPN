import Foundation
import Security

/// Минимальная обёртка над Keychain, общая для приложения и расширения Packet Tunnel.
///
/// Элементы сохраняются с `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, поэтому система
/// может (пере)запустить туннель, пока устройство заблокировано, а секреты никогда не покидают
/// устройство через резервные копии.
struct SecureStorage: Sendable {
    /// Ошибка работы с Keychain.
    enum Failure: Error, Equatable {
        /// Keychain вернул неожиданный код `OSStatus`.
        case unexpectedStatus(OSStatus)
    }

    /// Значение `kSecAttrService`, под которым лежат все элементы приложения.
    private let service: String
    /// Общая группа доступа Keychain; `nil` — использовать Keychain по умолчанию (сборка без подписи).
    private let accessGroup: String?

    /// Создаёт хранилище. Параметры меняются в тестах, чтобы не трогать боевые данные.
    init(service: String = "com.irklch.monovpn", accessGroup: String? = AppIdentifiers.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    /// Читает данные по ключу; `nil`, если элемента нет.
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

    /// Записывает данные по ключу: обновляет существующий элемент или добавляет новый.
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

    /// Удаляет элемент по ключу; отсутствие элемента ошибкой не считается.
    func remove(_ key: SecureStorageKey) throws {
        let status = SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Failure.unexpectedStatus(status)
        }
    }

    /// Читает значение по ключу как строку UTF-8.
    func string(for key: SecureStorageKey) throws -> String? {
        try data(for: key).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Записывает строку по ключу в кодировке UTF-8.
    func set(_ string: String, for key: SecureStorageKey) throws {
        try set(Data(string.utf8), for: key)
    }

    /// Базовый запрос к Keychain для ключа: класс, сервис, аккаунт и (если есть) группа доступа.
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
