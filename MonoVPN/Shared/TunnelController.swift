import Foundation
@preconcurrency import NetworkExtension

/// Connection state mirrored 1:1 from `NEVPNStatus`, the single source of truth.
enum VPNConnectionState: Equatable, Sendable {
    case invalid
    case disconnected
    case connecting
    case connected
    case reasserting
    case disconnecting

    init(_ status: NEVPNStatus) {
        switch status {
        case .invalid: self = .invalid
        case .disconnected: self = .disconnected
        case .connecting: self = .connecting
        case .connected: self = .connected
        case .reasserting: self = .reasserting
        case .disconnecting: self = .disconnecting
        @unknown default: self = .invalid
        }
    }

    /// Tunnel is up or coming up: a new configuration requires a restart.
    var isActive: Bool {
        switch self {
        case .connecting, .connected, .reasserting: true
        default: false
        }
    }

    var isTransitioning: Bool {
        switch self {
        case .connecting, .reasserting, .disconnecting: true
        default: false
        }
    }
}

enum VPNError: LocalizedError, Equatable {
    case permissionDenied
    case configurationFailed(String)
    case startFailed(String)
    case tunnel(String)
    case timeout

    // Strings live in the shared "Tunnel" table so the widget can show them too.
    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            String(localized: "error.vpn.permissionDenied", table: "Tunnel")
        case let .configurationFailed(message):
            String(localized: "error.vpn.configuration \(message)", table: "Tunnel")
        case let .startFailed(message):
            String(localized: "error.vpn.start \(message)", table: "Tunnel")
        case let .tunnel(message):
            String(localized: "error.vpn.tunnel \(message)", table: "Tunnel")
        case .timeout:
            String(localized: "error.vpn.timeout", table: "Tunnel")
        }
    }
}

/// Stateless NetworkExtension operations shared by the app (`VPNManager`) and the
/// widget's App Intent. Every call works on the manager it is given and re-reads the
/// status from the system, so it is safe to use from any process of the app.
enum TunnelController {
    /// The VPN configuration created by Mono VPN, or `nil` if it was never installed
    /// (or was removed in Settings).
    static func loadManager() async throws -> NETunnelProviderManager? {
        let managers = try await NETunnelProviderManager.loadAllFromPreferences()
        return managers.first { manager in
            (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppIdentifiers.tunnelBundleID
        }
    }

    /// Creates or updates the VPN configuration and enables it.
    ///
    /// Creating it shows the system "Add VPN Configuration" alert, so a missing
    /// configuration must be created from the app, never from the widget.
    static func install(_ existing: NETunnelProviderManager?) async throws -> NETunnelProviderManager {
        let manager = existing ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIdentifiers.tunnelBundleID
        // Shown in Settings → VPN. Not a real address: the server lives in the Keychain.
        proto.serverAddress = "Mono VPN"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Mono VPN"
        manager.isEnabled = true
        try await save(manager)
        return manager
    }

    /// Starts the tunnel. If another VPN app took over, re-enables Mono VPN first
    /// (an existing configuration is updated without a system prompt).
    static func start(_ manager: NETunnelProviderManager) async throws {
        if !manager.isEnabled {
            manager.isEnabled = true
            try await save(manager)
        }
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw VPNError.startFailed(error.localizedDescription)
        }
    }

    /// Stops the tunnel and waits for the system to confirm `.disconnected`.
    /// Returns `false` if the confirmation did not arrive within `timeout`.
    @discardableResult
    static func stop(_ manager: NETunnelProviderManager, timeout: Duration = .seconds(15)) async -> Bool {
        let connection = manager.connection
        switch connection.status {
        case .disconnected, .invalid:
            return true
        default:
            connection.stopVPNTunnel()
        }
        let status = await waitForStatus(of: connection, timeout: timeout) { $0 == .disconnected || $0 == .invalid }
        return status == .disconnected || status == .invalid
    }

    /// Waits (without polling) for `NEVPNStatusDidChange` until `predicate` holds or the
    /// timeout expires. Returns the last status reported by the system.
    static func waitForStatus(
        of connection: NEVPNConnection,
        timeout: Duration,
        until predicate: @escaping @Sendable (NEVPNStatus) -> Bool
    ) async -> NEVPNStatus {
        nonisolated(unsafe) let connection = connection
        // Subscribe before reading the status so a change in between is not missed.
        let changes = NotificationCenter.default.notifications(named: .NEVPNStatusDidChange, object: connection)
        if predicate(connection.status) { return connection.status }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                for await _ in changes where predicate(connection.status) {
                    return
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
            }
            await group.next()
            group.cancelAll()
        }
        return connection.status
    }

    private static func save(_ manager: NETunnelProviderManager) async throws {
        do {
            try await manager.saveToPreferences()
            // Required after saving, otherwise the next start can use a stale configuration.
            try await manager.loadFromPreferences()
        } catch {
            let nsError = error as NSError
            let deniedCodes = [NEVPNError.configurationReadWriteFailed.rawValue, NEVPNError.configurationDisabled.rawValue]
            if nsError.domain == NEVPNErrorDomain, deniedCodes.contains(nsError.code) {
                // The user tapped "Don't Allow" in the system alert.
                throw VPNError.permissionDenied
            }
            throw VPNError.configurationFailed(error.localizedDescription)
        }
    }
}
