import Foundation
import NetworkExtension

/// A connect / disconnect request coming from the widget, either through its
/// App Intent or through the `monovpn://` URL that opens the app.
///
/// Commands are idempotent ("connect" never stops a running tunnel), so a repeated
/// tap or a command delivered twice can never toggle the VPN back.
enum TunnelCommand: String, Sendable, Equatable {
    case connect
    case disconnect

    static let urlScheme = "monovpn"

    init?(url: URL) {
        guard url.scheme?.lowercased() == Self.urlScheme, let host = url.host()?.lowercased() else { return nil }
        self.init(rawValue: host)
    }

    var url: URL {
        // Static string built from a known scheme and case name: always valid.
        URL(string: "\(Self.urlScheme)://\(rawValue)") ?? URL(fileURLWithPath: "/")
    }

    enum Action: Equatable {
        case start
        case stop
        case none
    }

    /// What to do for this command given the real system status.
    func action(status: NEVPNStatus, hasConfiguration: Bool) -> Action {
        switch self {
        case .connect:
            guard hasConfiguration else { return .none }
            switch status {
            case .disconnected, .invalid: return .start
            default: return .none // already starting/running, or still stopping
            }
        case .disconnect:
            switch status {
            case .connecting, .connected, .reasserting: return .stop
            default: return .none
            }
        }
    }
}

/// What the widget shows. Derived from `NEVPNStatus` every time, never stored.
enum WidgetVPNState: Equatable, Sendable {
    /// No subscription or no selected server: nothing to connect to.
    case noServer
    /// A server is selected but the system VPN configuration is not installed yet
    /// (first connection must happen in the app, which shows the system prompt).
    case needsSetup
    case disconnected
    case connecting
    case connected
    case disconnecting
    /// The last start failed (reported by the tunnel or the widget).
    case failed

    static func resolve(status: NEVPNStatus?, hasConfiguration: Bool, lastError: String?) -> WidgetVPNState {
        switch status {
        case .connecting?, .reasserting?: return .connecting
        case .connected?: return .connected
        case .disconnecting?: return .disconnecting
        default: break
        }
        guard hasConfiguration else { return .noServer }
        guard let status, status != .invalid else { return .needsSetup }
        if let lastError, !lastError.isEmpty { return .failed }
        return .disconnected
    }

    /// Command issued by a tap, or `nil` if the widget is not interactive in this state.
    var command: TunnelCommand? {
        switch self {
        case .needsSetup, .disconnected, .failed: .connect
        case .connected, .connecting: .disconnect
        case .noServer, .disconnecting: nil
        }
    }

    var isTransitioning: Bool {
        self == .connecting || self == .disconnecting
    }
}

/// Executes widget commands with the shared `TunnelController`. Runs in whichever
/// process performs the App Intent (the widget extension) — no app UI involved.
enum WidgetCommandRunner {
    /// Reads the current state for the widget timeline.
    static func currentState(storage: SecureStorage = SecureStorage()) async -> WidgetVPNState {
        let hasConfiguration = (try? storage.data(for: .tunnelConfiguration)) != nil
        let lastError = try? storage.string(for: .lastTunnelError)
        let manager = try? await TunnelController.loadManager()
        return .resolve(status: manager?.connection.status, hasConfiguration: hasConfiguration, lastError: lastError)
    }

    /// Performs the command and waits (bounded) for the system to confirm the result.
    /// Errors are stored for the widget to display instead of pretending success.
    static func perform(_ command: TunnelCommand, storage: SecureStorage = SecureStorage()) async {
        let hasConfiguration = (try? storage.data(for: .tunnelConfiguration)) != nil
        guard let manager = try? await TunnelController.loadManager() else { return }

        switch command.action(status: manager.connection.status, hasConfiguration: hasConfiguration) {
        case .none:
            return
        case .start:
            try? storage.remove(.lastTunnelError)
            do {
                try await TunnelController.start(manager)
            } catch {
                try? storage.set(error.localizedDescription, for: .lastTunnelError)
                return
            }
            _ = await TunnelController.waitForStatus(of: manager.connection, timeout: .seconds(10)) {
                $0 == .connected || $0 == .disconnected || $0 == .invalid
            }
        case .stop:
            await TunnelController.stop(manager, timeout: .seconds(10))
        }
    }
}
