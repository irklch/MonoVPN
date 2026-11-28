import Foundation
@preconcurrency import NetworkExtension
import Observation
import os
import WidgetKit

#if DEBUG
/// Логгер категории «VPN» (только DEBUG): без адресов, ссылок и учётных данных.
private let vpnLogger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "VPN")
#endif

/// Владеет `NETunnelProviderManager` приложения и публикует системный статус VPN.
///
/// Системные операции делегируются `TunnelController`, которым пользуется и App Intent
/// виджета; этот класс лишь добавляет наблюдение для SwiftUI.
@MainActor
@Observable
final class VPNManager {
    /// Текущее состояние подключения, отражённое из системы.
    private(set) var state: VPNConnectionState = .invalid
    /// `connectedDate` системной VPN-сессии, пока она подключена.
    private(set) var connectedDate: Date?
    /// Последняя ошибка, о которой сообщила система или расширение.
    private(set) var lastError: VPNError?
    /// Загружена ли конфигурация хотя бы раз — до этого интерфейс не показывает статус.
    private(set) var isLoaded = false

    /// Системная конфигурация VPN Mono VPN; `nil`, если она ещё не установлена.
    @ObservationIgnored private var manager: NETunnelProviderManager?
    /// Токены подписок на уведомления NetworkExtension.
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    /// Отключение запросил пользователь — тогда переход в `.disconnected` не считается ошибкой.
    @ObservationIgnored private var userRequestedStop = false
    /// Выполняется connect/disconnect: параллельная операция получает `VPNError.busy`.
    @ObservationIgnored private var isOperating = false
    /// Keychain для конфигурации туннеля и последней ошибки.
    @ObservationIgnored private let storage: SecureStorage

    /// Создаёт менеджер и подписывается на изменения статуса и конфигурации VPN.
    init(storage: SecureStorage = SecureStorage()) {
        self.storage = storage
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .NEVPNStatusDidChange, object: nil, queue: .main) { [weak self] notification in
            // На главный актор передаётся только идентификатор; само соединение перечитывается там.
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

    /// Загружает существующую конфигурацию и текущий статус. Можно вызывать многократно
    /// (при запуске и при каждом возврате приложения на передний план).
    func load() async {
        do {
            manager = try await TunnelController.loadManager()
        } catch {
            #if DEBUG
            vpnLogger.error("Failed to load VPN preferences: \(String(describing: type(of: error)), privacy: .public)")
            #endif
        }
        isLoaded = true
        refreshStatus()
    }

    /// Перечитывает статус из системы (используется при возврате на передний план).
    func refreshStatus() {
        guard let connection = manager?.connection else {
            update(.disconnected, connectedDate: nil)
            return
        }
        apply(connection)
    }

    /// Сбрасывает показанную ошибку (после того как пользователь её закрыл).
    func clearError() {
        lastError = nil
    }

    /// Запускает туннель с переданной конфигурацией Xray.
    ///
    /// Если туннель уже поднят (например, из виджета), повторно не запускается;
    /// если он ещё отключается — сначала дожидается `.disconnected` (см. `TunnelController.start`).
    func connect(configuration: String) async throws {
        guard !isOperating else { throw VPNError.busy }
        isOperating = true
        defer { isOperating = false }

        lastError = nil
        userRequestedStop = false
        do {
            try storage.set(configuration, for: .tunnelConfiguration)
            try? storage.remove(.lastTunnelError)
            try? storage.remove(.widgetError)
        } catch {
            throw VPNError.configurationFailed(error.localizedDescription)
        }

        let manager = try await TunnelController.install(manager)
        self.manager = manager
        try await TunnelController.start(manager)
        apply(manager.connection)
    }

    /// Останавливает туннель и ждёт, пока система сообщит `.disconnected`.
    ///
    /// Бросает `VPNError.timeout`, если система не подтвердила остановку: туннель, возможно,
    /// ещё работает, и вызывающий не должен переподключаться или удалять конфигурацию.
    func disconnect() async throws {
        guard !isOperating else { throw VPNError.busy }
        isOperating = true
        defer {
            isOperating = false
            refreshStatus()
        }
        if manager == nil {
            // Туннель мог запустить виджет до того, как приложение загрузило конфигурацию.
            manager = try? await TunnelController.loadManager()
        }
        guard let manager else { return }
        userRequestedStop = true
        try await TunnelController.stop(manager)
    }

    /// Запрашивает у расширения счётчики трафика туннеля; `nil`, если туннель не запущен
    /// или расширение не ответило.
    func fetchTraffic() async -> TunnelTrafficSnapshot? {
        guard let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else { return nil }
        let response: Data? = await withCheckedContinuation { continuation in
            do {
                try session.sendProviderMessage(TunnelProviderMessage.trafficRequest) { data in
                    continuation.resume(returning: data)
                }
            } catch {
                continuation.resume(returning: nil)
            }
        }
        return response.flatMap { try? JSONDecoder().decode(TunnelTrafficSnapshot.self, from: $0) }
    }

    // MARK: - Приватное

    /// Обрабатывает `NEVPNStatusDidChange`: применяет новый статус и распознаёт неудачный запуск.
    ///
    /// Уведомления от чужих соединений (другие VPN-конфигурации) игнорируются.
    private func handleStatusChange(from source: ObjectIdentifier?) {
        guard let current = manager?.connection else {
            // Статус изменил виджет или Настройки ещё до того, как конфигурация загрузилась здесь.
            Task { await load() }
            return
        }
        if let source, source != ObjectIdentifier(current) { return }
        let previous = state
        apply(current)

        // connecting → disconnected без запроса пользователя означает, что запуск не удался.
        if state == .disconnected, previous == .connecting || previous == .reasserting, !userRequestedStop {
            Task { await reportDisconnectError(current) }
        }
        if state == .disconnected {
            userRequestedStop = false
        }
    }

    /// Применяет статус соединения; дата подключения берётся только в состоянии `.connected`.
    private func apply(_ connection: NEVPNConnection) {
        let newState = VPNConnectionState(connection.status)
        update(newState, connectedDate: newState == .connected ? connection.connectedDate : nil)
    }

    /// Сохраняет состояние и дату подключения; при смене состояния обновляет виджет.
    private func update(_ newState: VPNConnectionState, connectedDate: Date?) {
        let changed = newState != state
        state = newState
        self.connectedDate = connectedDate
        if changed {
            // Держим виджет на домашнем экране в соответствии с реальным статусом.
            WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
        }
    }

    /// Находит причину неожиданного отключения: сначала ошибку от расширения в Keychain,
    /// затем последнюю ошибку отключения из системы.
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
