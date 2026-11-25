import Foundation
import Observation
import WidgetKit

/// Состояние главного экрана: подписка, выбранный сервер и VPN-подключение.
///
/// Само состояние подключения здесь никогда не хранится: оно читается из
/// `VPNManager`, который отражает `NEVPNStatus`.
@MainActor
@Observable
final class HomeViewModel {
    /// Менеджер VPN — источник статуса подключения и ошибок системы.
    let vpn: VPNManager

    /// Сохраняемое состояние: подписка и выбранный сервер.
    private(set) var appState: AppState
    /// Идёт импорт новой подписки.
    private(set) var isImporting = false
    /// Идёт обновление текущей подписки.
    private(set) var isRefreshing = false
    /// Защита от повторных нажатий, пока выполняется запрос на запуск/остановку.
    private(set) var isPerformingAction = false

    /// Ошибка последнего импорта / обновления; показывается в окнах подписки и серверов.
    var subscriptionError: String?
    /// Ошибка последней попытки подключения из приложения.
    var connectionError: String?
    /// Показывать ли уведомление о конфиденциальности перед первым подключением.
    var isPrivacyNoticePresented = false

    /// Хранилище состояния и конфигурации туннеля в Keychain.
    @ObservationIgnored private let store: AppStateStore
    /// Сервис загрузки и разбора подписок.
    @ObservationIgnored private let service: SubscriptionService

    /// Создаёт модель и загружает сохранённое состояние; зависимости подменяются в тестах.
    init(
        vpn: VPNManager = VPNManager(),
        store: AppStateStore = AppStateStore(),
        service: SubscriptionService = SubscriptionService()
    ) {
        self.vpn = vpn
        self.store = store
        self.service = service
        appState = store.load()
        // Для существующих установок: виджет должен найти конфигурацию выбранного сервера.
        syncTunnelConfiguration()
    }

    // MARK: - Производное состояние

    /// Текущая подписка или `nil`.
    var subscription: Subscription? { appState.subscription }
    /// Выбранный сервер или `nil`, если подписки нет.
    var selectedServer: ServerConfiguration? { appState.selectedServer }
    /// Все серверы текущей подписки.
    var servers: [ServerConfiguration] { appState.subscription?.servers ?? [] }
    /// Состояние подключения из `VPNManager`.
    var state: VPNConnectionState { vpn.state }

    /// Занят ли экран: идёт действие пользователя или переходное состояние VPN.
    var isBusy: Bool {
        isPerformingAction || vpn.state.isTransitioning
    }

    /// Можно ли сейчас нажать кнопку подключения: статус загружен, сервер выбран и ничего не выполняется.
    var canToggleConnection: Bool {
        vpn.isLoaded && selectedServer != nil && !isBusy
    }

    /// Ошибка под кнопкой подключения: сначала ошибка приложения, затем системы/расширения.
    var visibleConnectionError: String? {
        connectionError ?? vpn.lastError?.localizedDescription
    }

    // MARK: - Жизненный цикл

    /// Вызывается при запуске приложения: загружает конфигурацию и статус VPN.
    func start() async {
        await vpn.load()
    }

    /// Вызывается при возврате на передний план: перечитывает статус VPN из системы.
    func sceneDidBecomeActive() async {
        await vpn.load()
    }

    /// Выполняет команду, пришедшую от виджета через `monovpn://` (используется, когда
    /// системная конфигурация VPN ещё не существует и её нужно создать в приложении).
    /// Команды идемпотентны: повторная доставка никогда не переключает VPN обратно.
    func handle(_ command: TunnelCommand) async {
        if !vpn.isLoaded {
            await vpn.load()
        }
        switch command {
        case .connect:
            guard selectedServer != nil, !vpn.state.isActive, !isBusy else { return }
            await toggleConnection()
        case .disconnect:
            guard vpn.state.isActive, !isBusy else { return }
            await toggleConnection()
        }
    }

    // MARK: - Подключение

    /// Обработчик главной кнопки: отключает активный VPN, иначе подключает
    /// (перед первым подключением показывает уведомление о конфиденциальности).
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

    /// Запоминает принятие уведомления о конфиденциальности, закрывает его и подключается.
    func acceptPrivacyNotice() async {
        Preferences.isPrivacyNoticeAccepted = true
        isPrivacyNoticePresented = false
        await connect()
    }

    /// Строит конфигурацию для выбранного сервера и запускает туннель; ошибку показывает под кнопкой.
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

    /// Останавливает туннель и ждёт подтверждения от системы.
    private func disconnect() async {
        guard !isPerformingAction else { return }
        isPerformingAction = true
        defer { isPerformingAction = false }
        clearErrors()
        await vpn.disconnect()
    }

    /// Сбрасывает ошибки приложения и VPN перед новым действием.
    private func clearErrors() {
        connectionError = nil
        vpn.clearError()
    }

    // MARK: - Серверы

    /// Выбирает сервер, сохраняет выбор и обновляет конфигурацию для виджета;
    /// если VPN был активен — переподключается к новому серверу.
    func select(_ server: ServerConfiguration) async {
        guard server.id != selectedServer?.id else { return }
        let wasActive = vpn.state.isActive
        appState.selectedServerID = server.id
        persist()
        syncTunnelConfiguration()
        if wasActive {
            await restart(with: server)
        }
    }

    /// Останавливает текущий туннель и запускает новый с указанным сервером.
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

    // MARK: - Подписка

    /// Импортирует новую подписку (URL или одиночную ссылку), заменяя текущую.
    /// Возвращает `true` при успехе.
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
            // Предыдущая подписка остаётся нетронутой.
            subscriptionError = error.localizedDescription
            return false
        }
    }

    /// Заново скачивает текущую подписку. При ошибке сохраняется последняя рабочая.
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

    /// Отключает VPN (если нужно) и удаляет подписку и все секреты.
    func deleteSubscription() async {
        // Останавливаем безусловно (даже если выполняется другое действие):
        // конфигурация не должна пережить подписку, из которой она получена.
        if vpn.state != .disconnected, vpn.state != .invalid {
            await vpn.disconnect()
        }
        do {
            try store.removeAll()
            appState = AppState()
            subscriptionError = nil
            connectionError = nil
        } catch {
            subscriptionError = error.localizedDescription
        }
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
    }

    /// Применяет новую подписку: сохраняет её, обновляет конфигурацию туннеля и при
    /// необходимости перезапускает VPN.
    private func apply(_ subscription: Subscription) async {
        let previousServer = selectedServer
        appState.replaceSubscription(with: subscription)
        persist()
        syncTunnelConfiguration()

        // Работающий туннель использует старые параметры: перезапускаем, если они изменились.
        if vpn.state.isActive, let server = selectedServer, server != previousServer {
            await restart(with: server)
        }
    }

    /// Поддерживает актуальной копию конфигурации sing-box выбранного сервера в Keychain.
    /// Виджет запускает туннель именно с этой конфигурацией и никогда не выбирает
    /// сервер сам; без выбранного сервера элемент удаляется («Нет сервера»).
    private func syncTunnelConfiguration() {
        do {
            if let server = selectedServer {
                try store.saveTunnelConfiguration(VPNConfigurationBuilder.build(for: server))
            } else {
                try store.removeTunnelConfiguration()
            }
        } catch {
            subscriptionError = String(localized: "error.storage \(error.localizedDescription)")
        }
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
    }

    /// Сохраняет `appState` в Keychain; ошибку показывает как ошибку подписки.
    private func persist() {
        do {
            try store.save(appState)
        } catch {
            subscriptionError = String(localized: "error.storage \(error.localizedDescription)")
        }
    }
}
