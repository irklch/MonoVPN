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
        do {
            try await vpn.disconnect()
        } catch {
            connectionError = error.localizedDescription
        }
    }

    /// Сбрасывает ошибки приложения и VPN перед новым действием.
    private func clearErrors() {
        connectionError = nil
        vpn.clearError()
    }

    // MARK: - Серверы

    /// Выбирает сервер, сохраняет выбор и обновляет конфигурацию для виджета;
    /// если VPN был активен — переподключается к новому серверу.
    ///
    /// Если старый туннель не удалось остановить, выбор не меняется: выбранный сервер
    /// всегда совпадает с тем, что реально запущено.
    func select(_ server: ServerConfiguration) async {
        guard server.isSupported, server.id != selectedServer?.id else { return }
        await switchTunnel {
            appState.selectedServerID = server.id
        }
    }

    /// Применяет `commit` (смену выбранного сервера или подписки) так, чтобы работающий
    /// туннель никогда не расходился с сохранённым выбором.
    ///
    /// Туннель не работает — изменение просто сохраняется. Работает — сначала он
    /// останавливается с подтверждением системы; только после этого изменение сохраняется
    /// и туннель запускается с новым сервером. Возвращает `false`, если изменение не применено
    /// (туннель не остановился или уже выполняется другое действие); причина — в `connectionError`.
    @discardableResult
    private func switchTunnel(_ commit: () -> Void) async -> Bool {
        guard vpn.state != .disconnected, vpn.state != .invalid else {
            commit()
            persist()
            syncTunnelConfiguration()
            return true
        }
        guard !isPerformingAction else {
            connectionError = VPNError.busy.localizedDescription
            return false
        }
        isPerformingAction = true
        defer { isPerformingAction = false }
        clearErrors()
        do {
            try await vpn.disconnect()
        } catch {
            connectionError = error.localizedDescription
            return false
        }
        commit()
        persist()
        syncTunnelConfiguration()
        guard let server = selectedServer else { return true }
        do {
            try await vpn.connect(configuration: VPNConfigurationBuilder.build(for: server))
        } catch {
            connectionError = error.localizedDescription
        }
        return true
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
            guard await apply(subscription) else {
                subscriptionError = String(localized: "error.switch.notStopped")
                return false
            }
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
            if await !apply(subscription) {
                subscriptionError = String(localized: "error.switch.notStopped")
            }
        } catch {
            subscriptionError = error.localizedDescription
        }
    }

    /// Отключает VPN (если нужно) и удаляет подписку и все секреты.
    ///
    /// Если туннель не удалось остановить, ничего не удаляется: работающий туннель
    /// не должен остаться без подписки и конфигурации, из которых он получен.
    func deleteSubscription() async {
        if vpn.state != .disconnected, vpn.state != .invalid {
            do {
                try await vpn.disconnect()
            } catch {
                subscriptionError = error.localizedDescription
                return
            }
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
    /// необходимости перезапускает VPN. Возвращает `false`, если работающий туннель
    /// не удалось остановить — тогда подписка остаётся прежней.
    private func apply(_ subscription: Subscription) async -> Bool {
        var updated = appState
        updated.replaceSubscription(with: subscription)
        let commit = { self.appState = updated }

        // Работающий туннель использует старые параметры: перезапускаем, если они изменились.
        guard updated.selectedServer != selectedServer else {
            commit()
            persist()
            syncTunnelConfiguration()
            return true
        }
        return await switchTunnel(commit)
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
