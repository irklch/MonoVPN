import Foundation
import NetworkExtension
import Observation
import os

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

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            String(localized: "error.vpn.permissionDenied")
        case let .configurationFailed(message):
            String(localized: "error.vpn.configuration \(message)")
        case let .startFailed(message):
            String(localized: "error.vpn.start \(message)")
        case let .tunnel(message):
            String(localized: "error.vpn.tunnel \(message)")
        case .timeout:
            String(localized: "error.vpn.timeout")
        }
    }
}

/// Owns the app's `NETunnelProviderManager` and publishes the system VPN status.
@MainActor
@Observable
final class VPNManager {
    private(set) var state: VPNConnectionState = .invalid
    /// `connectedDate` of the system VPN session while connected.
    private(set) var connectedDate: Date?
    /// Last failure reported by the system or the extension.
    private(set) var lastError: VPNError?
    private(set) var isLoaded = false

    @ObservationIgnored private var manager: NETunnelProviderManager?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var userRequestedStop = false
    @ObservationIgnored private let storage: SecureStorage
    @ObservationIgnored private let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "VPN")

    init(storage: SecureStorage = SecureStorage()) {
        self.storage = storage
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            // Only the identity crosses into the main actor; the connection is re-read there.
            let source = (notification.object as? NEVPNConnection).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                self?.handleStatusChange(from: source)
            }
        })
        observers.append(center.addObserver(forName: .NEVPNConfigurationChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.load() }
            }
        })
    }

    /// Loads the existing configuration and the current status. Safe to call repeatedly
    /// (on launch and whenever the app returns to the foreground).
    func load() async {
        do {
            let managers = try await NETunnelProviderManager.loadAllFromPreferences()
            manager = managers.first { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?.providerBundleIdentifier == AppIdentifiers.tunnelBundleID
            }
        } catch {
            logger.error("Failed to load VPN preferences: \(error.localizedDescription, privacy: .public)")
        }
        isLoaded = true
        refreshStatus()
    }

    /// Re-reads the status from the system (used when returning to the foreground).
    func refreshStatus() {
        guard let connection = manager?.connection else {
            state = .disconnected
            connectedDate = nil
            return
        }
        apply(connection)
    }

    func clearError() {
        lastError = nil
    }

    /// Starts the tunnel with the given sing-box configuration.
    func connect(configuration: String) async throws {
        lastError = nil
        userRequestedStop = false
        do {
            try storage.set(configuration, for: .tunnelConfiguration)
        } catch {
            throw VPNError.configurationFailed(error.localizedDescription)
        }

        let manager = try await preparedManager()
        do {
            try manager.connection.startVPNTunnel()
        } catch {
            throw VPNError.startFailed(error.localizedDescription)
        }
        apply(manager.connection)
    }

    /// Stops the tunnel and waits until the system reports `.disconnected`.
    func disconnect() async {
        guard let connection = manager?.connection else { return }
        userRequestedStop = true
        if connection.status != .disconnected, connection.status != .invalid {
            connection.stopVPNTunnel()
        }
        _ = await waitForStatus(timeout: .seconds(15)) { $0 == .disconnected || $0 == .invalid }
    }

    /// Restarts the tunnel with a new configuration (server switch).
    func reconnect(configuration: String) async throws {
        await disconnect()
        try await connect(configuration: configuration)
    }

    // MARK: - Private

    /// Creates or updates the VPN configuration. The first save shows the system
    /// "Add VPN Configuration" permission alert.
    private func preparedManager() async throws -> NETunnelProviderManager {
        let manager = self.manager ?? NETunnelProviderManager()
        let proto = (manager.protocolConfiguration as? NETunnelProviderProtocol) ?? NETunnelProviderProtocol()
        proto.providerBundleIdentifier = AppIdentifiers.tunnelBundleID
        // Shown in Settings → VPN. Not a real address: the server lives in the Keychain.
        proto.serverAddress = "Mono VPN"
        proto.disconnectOnSleep = false
        manager.protocolConfiguration = proto
        manager.localizedDescription = "Mono VPN"
        manager.isEnabled = true

        do {
            try await manager.saveToPreferences()
            // Required after saving, otherwise the first start fails with a stale configuration.
            try await manager.loadFromPreferences()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationReadWriteFailed.rawValue {
                // The user tapped "Don't Allow" in the system alert.
                throw VPNError.permissionDenied
            }
            if nsError.domain == NEVPNErrorDomain, nsError.code == NEVPNError.configurationDisabled.rawValue {
                throw VPNError.permissionDenied
            }
            throw VPNError.configurationFailed(error.localizedDescription)
        }
        self.manager = manager
        return manager
    }

    private func handleStatusChange(from source: ObjectIdentifier?) {
        guard let current = manager?.connection else {
            // The configuration may still be in the middle of being created.
            return
        }
        if let source, source != ObjectIdentifier(current) { return }
        let previous = state
        apply(current)

        // connecting → disconnected without a user request means the start failed.
        if state == .disconnected, previous == .connecting || previous == .reasserting, !userRequestedStop {
            Task { await reportDisconnectError(current) }
        }
        if state == .disconnected {
            userRequestedStop = false
        }
    }

    private func apply(_ connection: NEVPNConnection) {
        state = VPNConnectionState(connection.status)
        connectedDate = state == .connected ? connection.connectedDate : nil
    }

    private func reportDisconnectError(_ connection: NEVPNConnection) async {
        if let message = try? storage.string(for: .lastTunnelError), !message.isEmpty {
            lastError = .tunnel(message)
            return
        }
        do {
            try await connection.fetchLastDisconnectError()
        } catch {
            lastError = .tunnel(error.localizedDescription)
        }
    }

    private func waitForStatus(timeout: Duration, _ predicate: (VPNConnectionState) -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while clock.now < deadline {
            refreshStatus()
            if predicate(state) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}
