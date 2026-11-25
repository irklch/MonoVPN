import Foundation
import Observation

/// Main screen state: subscription, selected server and the VPN connection.
///
/// The connection state itself is never stored here: it is read from
/// `VPNManager`, which mirrors `NEVPNStatus`.
@MainActor
@Observable
final class HomeViewModel {
    let vpn: VPNManager

    private(set) var appState: AppState
    private(set) var isImporting = false
    private(set) var isRefreshing = false
    /// Guards against repeated taps while a start/stop request is being issued.
    private(set) var isPerformingAction = false

    /// Error of the last import / refresh, shown in the subscription and server sheets.
    var subscriptionError: String?
    /// Error of the last connect attempt issued from the app.
    var connectionError: String?
    var isPrivacyNoticePresented = false

    @ObservationIgnored private let store: AppStateStore
    @ObservationIgnored private let service: SubscriptionService

    init(
        vpn: VPNManager = VPNManager(),
        store: AppStateStore = AppStateStore(),
        service: SubscriptionService = SubscriptionService()
    ) {
        self.vpn = vpn
        self.store = store
        self.service = service
        appState = store.load()
    }

    // MARK: - Derived state

    var subscription: Subscription? { appState.subscription }
    var selectedServer: ServerConfiguration? { appState.selectedServer }
    var servers: [ServerConfiguration] { appState.subscription?.servers ?? [] }
    var state: VPNConnectionState { vpn.state }

    var isBusy: Bool {
        isPerformingAction || vpn.state.isTransitioning
    }

    var canToggleConnection: Bool {
        vpn.isLoaded && selectedServer != nil && !isBusy
    }

    /// Error to show under the connect button: app-side first, then the system/extension one.
    var visibleConnectionError: String? {
        connectionError ?? vpn.lastError?.localizedDescription
    }

    // MARK: - Lifecycle

    func start() async {
        await vpn.load()
    }

    func sceneDidBecomeActive() async {
        await vpn.load()
    }

    // MARK: - Connection

    func toggleConnection() async {
        guard canToggleConnection else { return }
        if vpn.state.isActive {
            await disconnect()
        } else if !Preferences.isPrivacyNoticeAccepted {
            isPrivacyNoticePresented = true
        } else {
            await connect()
        }
    }

    func acceptPrivacyNotice() async {
        Preferences.isPrivacyNoticeAccepted = true
        isPrivacyNoticePresented = false
        await connect()
    }

    private func connect() async {
        guard let server = selectedServer, !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        clearErrors()
        do {
            let configuration = try VPNConfigurationBuilder.build(for: server)
            try await vpn.connect(configuration: configuration)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    private func disconnect() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        clearErrors()
        await vpn.disconnect()
    }

    private func clearErrors() {
        connectionError = nil
        vpn.clearError()
    }

    // MARK: - Servers

    func select(_ server: ServerConfiguration) async {
        guard server.id != selectedServer?.id else { return }
        let wasActive = vpn.state.isActive
        appState.selectedServerID = server.id
        persist()
        if wasActive {
            await restart(with: server)
        }
    }

    /// Stops the current tunnel and starts a new one with the given server.
    private func restart(with server: ServerConfiguration) async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        clearErrors()
        do {
            let configuration = try VPNConfigurationBuilder.build(for: server)
            try await vpn.reconnect(configuration: configuration)
        } catch {
            connectionError = error.localizedDescription
        }
    }

    // MARK: - Subscription

    /// Imports a new subscription (URL or single link), replacing the current one.
    /// Returns `true` on success.
    @discardableResult
    func importSubscription(from input: String) async -> Bool {
        guard !isImporting else { return false }
        isImporting = true
        defer { isImporting = false }
        subscriptionError = nil
        do {
            let subscription = try await service.importSubscription(from: input)
            await apply(subscription)
            return true
        } catch {
            // The previous subscription stays untouched.
            subscriptionError = error.localizedDescription
            return false
        }
    }

    /// Re-downloads the current subscription. On failure the last valid one is kept.
    func refreshSubscription() async {
        guard let source = appState.subscription?.source, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        subscriptionError = nil
        do {
            let subscription = try await service.refresh(source)
            await apply(subscription)
        } catch {
            subscriptionError = error.localizedDescription
        }
    }

    /// Disconnects the VPN (if needed) and removes the subscription and all secrets.
    func deleteSubscription() async {
        if vpn.state != .disconnected, vpn.state != .invalid {
            await disconnect()
        }
        do {
            try store.removeAll()
            appState = AppState()
            subscriptionError = nil
            connectionError = nil
        } catch {
            subscriptionError = error.localizedDescription
        }
    }

    private func apply(_ subscription: Subscription) async {
        let previousServer = selectedServer
        appState.subscription = subscription
        if let id = appState.selectedServerID, subscription.servers.contains(where: { $0.id == id }) {
            // Keep the user's choice.
        } else {
            appState.selectedServerID = subscription.servers.first?.id
        }
        persist()

        // The running tunnel uses the old parameters: restart if they changed.
        if vpn.state.isActive, let server = selectedServer, server != previousServer {
            await restart(with: server)
        }
    }

    private func persist() {
        do {
            try store.save(appState)
        } catch {
            subscriptionError = String(localized: "error.storage \(error.localizedDescription)")
        }
    }
}
