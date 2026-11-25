import Foundation
import Libbox
import NetworkExtension
import os
import WidgetKit

/// System VPN tunnel backed by the sing-box core (Libbox).
///
/// The app writes a ready sing-box configuration to the shared Keychain before
/// starting the tunnel; the extension reads it here. Reading it from the Keychain
/// (instead of `startVPNTunnel(options:)`) keeps the tunnel restartable by the
/// system and from Settings, including while the device is locked.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "PacketTunnel")

    private let storage = SecureStorage()
    private var commandServer: LibboxCommandServer?
    private lazy var platformInterface = TunnelPlatformInterface(provider: self)

    override init() {
        LibboxPrepareCrashSignalHandlers()
        super.init()
    }

    override func startTunnel(options _: [String: NSObject]?) async throws {
        try? storage.remove(.lastTunnelError)
        do {
            try startCore()
            Self.logger.info("Tunnel started")
            reloadWidget()
        } catch {
            let message = (error as NSError).localizedDescription
            try? storage.set(message, for: .lastTunnelError)
            Self.logger.error("Tunnel start failed")
            stopCore()
            reloadWidget()
            throw error
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason) async {
        Self.logger.info("Stopping tunnel, reason \(reason.rawValue, privacy: .public)")
        stopCore()
        reloadWidget()
    }

    /// Lets the Home Screen widget pick up the new status, also when the VPN is
    /// toggled from Settings or restarted by the system while the app is closed.
    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
    }

    // MARK: - Core lifecycle

    private func startCore() throws {
        guard let configuration = try storage.string(for: .tunnelConfiguration), !configuration.isEmpty else {
            throw TunnelError.missingConfiguration
        }

        let paths = try TunnelPaths.prepare()
        let options = LibboxSetupOptions()
        options.basePath = paths.base.path
        options.workingPath = paths.working.path
        options.tempPath = paths.temp.path
        options.logMaxLines = 300
        options.debug = false
        options.crashReportSource = "NetworkExtension"
        options.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        options.appMarketingVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        // Lets sing-box shed connections before iOS kills the extension at its memory limit.
        options.oomKillerEnabled = true

        var setupError: NSError?
        LibboxSetup(options, &setupError)
        if let setupError {
            throw TunnelError.core(setupError.localizedDescription)
        }
        LibboxReinstallCrashSignalHandlers()

        var serverError: NSError?
        guard let server = LibboxNewCommandServer(platformInterface, platformInterface, &serverError) else {
            throw TunnelError.core(serverError?.localizedDescription ?? "command server")
        }
        commandServer = server
        do {
            try server.start()
            try server.startOrReloadService(configuration, options: LibboxOverrideOptions())
        } catch {
            throw TunnelError.core((error as NSError).localizedDescription)
        }
    }

    private func stopCore() {
        if let commandServer {
            try? commandServer.closeService()
            commandServer.close()
        }
        commandServer = nil
        platformInterface.reset()
    }

    /// Called by the core when the service asks to stop itself.
    func serviceStopRequested() {
        stopCore()
        cancelTunnelWithError(nil)
    }
}

enum TunnelError: LocalizedError {
    case missingConfiguration
    case core(String)

    var errorDescription: String? {
        switch self {
        case .missingConfiguration:
            String(localized: "tunnel.error.missingConfiguration", table: "Tunnel")
        case let .core(message):
            String(localized: "tunnel.error.core \(message)", table: "Tunnel")
        }
    }
}

/// Directories used by Libbox inside the App Group container.
struct TunnelPaths {
    let base: URL
    let working: URL
    let temp: URL

    static func prepare() throws -> TunnelPaths {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: AppIdentifiers.appGroup
        ) else {
            throw TunnelError.core("App Group container is unavailable")
        }
        let base = container.appendingPathComponent("Tunnel", isDirectory: true)
        let working = base.appendingPathComponent("Working", isDirectory: true)
        let temp = container.appendingPathComponent("Library/Caches/Tunnel", isDirectory: true)
        for url in [base, working, temp] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return TunnelPaths(base: base, working: working, temp: temp)
    }
}
