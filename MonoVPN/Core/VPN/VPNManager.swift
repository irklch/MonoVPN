import Foundation
@preconcurrency import NetworkExtension
import Observation
import os
import WidgetKit

/// Owns the app's `NETunnelProviderManager` and publishes the system VPN status.
///
/// System operations are delegated to `TunnelController`, which the widget's App
/// Intent uses as well; this class only adds observation for SwiftUI.
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
            manager = try await TunnelController.loadManager()
        } catch {
            logger.error("Failed to load VPN preferences: \(error.localizedDescription, privacy: .public)")
        }
        isLoaded = true
        refreshStatus()
    }

    /// Re-reads the status from the system (used when returning to the foreground).
    func refreshStatus() {
        guard let connection = manager?.connection else {
            update(.disconnected, connectedDate: nil)
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
            try? storage.remove(.lastTunnelError)
        } catch {
            throw VPNError.configurationFailed(error.localizedDescription)
        }

        let manager = try await TunnelController.install(manager)
        self.manager = manager
        try await TunnelController.start(manager)
        apply(manager.connection)
    }

    /// Stops the tunnel and waits until the system reports `.disconnected`.
    func disconnect() async {
        guard let manager else { return }
        userRequestedStop = true
        await TunnelController.stop(manager)
        refreshStatus()
    }

    /// Restarts the tunnel with a new configuration (server switch).
    func reconnect(configuration: String) async throws {
        await disconnect()
        try await connect(configuration: configuration)
    }

    // MARK: - Private

    private func handleStatusChange(from source: ObjectIdentifier?) {
        guard let current = manager?.connection else {
            // Changed by the widget or Settings before the configuration was loaded here.
            Task { await load() }
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
        let newState = VPNConnectionState(connection.status)
        update(newState, connectedDate: newState == .connected ? connection.connectedDate : nil)
    }

    private func update(_ newState: VPNConnectionState, connectedDate: Date?) {
        let changed = newState != state
        state = newState
        self.connectedDate = connectedDate
        if changed {
            // Keep the Home Screen widget in sync with the real status.
            WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
        }
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
}
