import Foundation
import os

/// Persists `AppState` (subscription, servers, selection) and the active tunnel
/// configuration in the Keychain. Nothing secret goes to `UserDefaults`.
struct AppStateStore: Sendable {
    private let storage: SecureStorage
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Storage")

    init(storage: SecureStorage = SecureStorage()) {
        self.storage = storage
    }

    func load() -> AppState {
        do {
            guard let data = try storage.data(for: .appState) else { return AppState() }
            return try JSONDecoder().decode(AppState.self, from: data)
        } catch {
            // Never log the payload itself, only the failure kind.
            Self.logger.error("Failed to load app state: \(String(describing: type(of: error)), privacy: .public)")
            return AppState()
        }
    }

    func save(_ state: AppState) throws {
        let data = try JSONEncoder().encode(state)
        try storage.set(data, for: .appState)
    }

    /// Stores the sing-box configuration read by the Packet Tunnel on start.
    func saveTunnelConfiguration(_ json: String) throws {
        try storage.set(json, for: .tunnelConfiguration)
    }

    func removeTunnelConfiguration() throws {
        try storage.remove(.tunnelConfiguration)
    }

    func removeAll() throws {
        try storage.remove(.appState)
        try storage.remove(.tunnelConfiguration)
        try storage.remove(.lastTunnelError)
    }
}

/// Non-secret UI preferences.
enum Preferences {
    private static let privacyNoticeKey = "privacyNoticeAccepted"

    static var isPrivacyNoticeAccepted: Bool {
        get { UserDefaults.standard.bool(forKey: privacyNoticeKey) }
        set { UserDefaults.standard.set(newValue, forKey: privacyNoticeKey) }
    }
}
