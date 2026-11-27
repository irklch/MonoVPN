#if MONO_CORE_XRAY
import Foundation
import Network
import NetworkExtension
import os
import WidgetKit

/// Системный VPN-туннель на ядре Xray-core (LibXray). Сборка с флагом `MONO_CORE_XRAY`.
///
/// Порядок запуска:
/// 1. Конфигурация Xray читается из общего Keychain (её пишет приложение; так туннель могут
///    перезапускать система, Настройки и виджет, в том числе на заблокированном устройстве).
/// 2. Имя сервера разрешается в IP **до** применения сетевых настроек туннеля: пока туннель
///    не поднят, системный DNS ещё не указывает в него, поэтому цикла «DNS → туннель → сервер»
///    нет. SNI и Host в конфигурации заданы явно, поэтому подмена адреса на IP ничего не меняет.
/// 3. `NEPacketTunnelNetworkSettings`: IPv4 и IPv6 с маршрутами по умолчанию (IPv6 не обходит
///    туннель), DNS — адрес внутри туннеля (`XrayTunnelLayout.dnsServer`) для всех доменов.
/// 4. Дескриптор utun ищется публичным `getsockopt` и передаётся Xray через `env["xray.tun.fd"]`;
///    Xray работает с дубликатом дескриптора (`proxy/tun/tun_darwin.go`), tun2socks не нужен.
/// 5. `runXray`. Собственные сокеты процесса Packet Tunnel iOS не направляет в туннель,
///    поэтому соединения Xray с сервером и `freedom` для LAN идут мимо него — без циклов.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    /// Логгер категории «PacketTunnel»; без адресов и секретов.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "PacketTunnel")

    /// Keychain с конфигурацией туннеля и последней ошибкой запуска.
    private let storage = SecureStorage()
    /// Диагностика в контейнере App Group.
    private let diagnostics = TunnelDiagnosticsStore()
    /// Измерение памяти, пока туннель работает.
    private let memoryMonitor = TunnelMemoryMonitor()
    /// Наблюдение за сменой сети (только запись событий в диагностику).
    private var pathMonitor: NWPathMonitor?
    /// Работает ли ядро, запущенное этим провайдером.
    private var isCoreRunning = false
    /// Счётчики трафика для главного экрана приложения.
    private let traffic = TunnelTrafficResponder()

    // MARK: - Жизненный цикл

    /// Поднимает туннель и запускает Xray; при ошибке сохраняет очищенный текст для приложения
    /// и виджета, освобождает ресурсы и пробрасывает ошибку системе.
    override func startTunnel(options _: [String: NSObject]?) async throws {
        let startedAt = Date()
        try? storage.remove(.lastTunnelError)
        diagnostics.update { state in
            if state.endedWithoutStop {
                // stopTunnel не вызывался: расширение было завершено (например, по лимиту памяти).
                state.record("Предыдущая сессия завершилась без остановки туннеля (пик памяти \(state.peakFootprintMB.map { "\($0) МБ" } ?? "—"))")
            }
            state.startedAt = startedAt
            state.lastStartError = nil
            state.startDuration = nil
            state.coreStartDuration = nil
            state.peakFootprintMB = nil
            state.record("Запуск туннеля")
        }

        do {
            try await startTunnelAndCore()
            let duration = Date().timeIntervalSince(startedAt)
            diagnostics.update { state in
                state.startDuration = (duration * 1000).rounded() / 1000
                state.record("Туннель запущен за \(String(format: "%.2f", duration)) с")
            }
            memoryMonitor.start()
            startPathMonitor()
            Self.logger.info("Tunnel started")
            reloadWidget()
        } catch {
            let message = TunnelErrorSanitizer.sanitize((error as NSError).localizedDescription)
            try? storage.set(message, for: .lastTunnelError)
            diagnostics.update { state in
                state.lastStartError = message
                state.record("Ошибка запуска: \(message)")
            }
            Self.logger.error("Tunnel start failed: \(message, privacy: .public)")
            stopCore()
            reloadWidget()
            throw TunnelError.core(message)
        }
    }

    /// Вызывается системой при остановке туннеля: останавливает ядро, записывает причину.
    override func stopTunnel(with reason: NEProviderStopReason) async {
        let name = Self.describe(reason)
        Self.logger.info("Stopping tunnel, reason \(name, privacy: .public)")
        pathMonitor?.cancel()
        pathMonitor = nil
        memoryMonitor.stop()
        stopCore()
        traffic.setInterfaceName(nil)
        diagnostics.update { state in
            state.stoppedAt = .now
            state.stopReason = name
            state.record("Остановка: \(name)")
        }
        reloadWidget()
    }

    /// Даёт виджету подхватить новый статус.
    /// Сообщения от приложения: сейчас только запрос счётчиков трафика.
    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        completionHandler?(traffic.response(to: messageData))
    }

    private func reloadWidget() {
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
    }

    // MARK: - Запуск

    /// Шаги 1–5 из описания класса.
    private func startTunnelAndCore() async throws {
        guard let template = try storage.string(for: .tunnelConfiguration), !template.isEmpty else {
            throw TunnelError.missingConfiguration
        }

        // 2. Адрес сервера — до сетевых настроек туннеля.
        let address = try XrayRuntimeConfiguration.serverAddress(in: template)
        var resolved: String?
        if !Self.isIPAddress(address) {
            resolved = Self.resolve(address)
            if resolved == nil {
                // Не удалось — Xray разрешит имя сам при подключении.
                diagnostics.update { $0.record("Имя сервера не разрешено заранее") }
            }
        }

        // 3. Сетевые настройки туннеля.
        try await setTunnelNetworkSettings(Self.networkSettings())

        // 4. Дескриптор utun.
        guard let tun = TunnelFileDescriptor.find() else {
            throw TunnelError.core("TUN file descriptor not found")
        }
        traffic.setInterfaceName(tun.interfaceName)
        let configuration = try XrayRuntimeConfiguration.prepare(
            template,
            tunFileDescriptor: tun.fd,
            resolvedServerAddress: resolved
        )

        // 5. Ядро.
        let coreStart = Date()
        try XrayCore.run(configuration: configuration)
        isCoreRunning = true
        let coreDuration = Date().timeIntervalSince(coreStart)
        let version = XrayCore.version().map { "Xray \($0)" } ?? "Xray"
        diagnostics.update { state in
            state.core = version
            state.coreStartDuration = (coreDuration * 1000).rounded() / 1000
            state.record("\(version) запущен за \(String(format: "%.3f", coreDuration)) с на \(tun.interfaceName)")
        }
    }

    /// Останавливает Xray; безопасно вызывать повторно.
    private func stopCore() {
        guard isCoreRunning || XrayCore.isRunning() else { return }
        do {
            try XrayCore.stop()
        } catch {
            diagnostics.update { $0.record("Ошибка остановки ядра: \(error.localizedDescription)") }
        }
        isCoreRunning = false
    }

    /// Сетевые настройки туннеля: адреса и маршруты по умолчанию IPv4/IPv6, DNS внутри туннеля, MTU.
    static func networkSettings() -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: XrayTunnelLayout.mtu)

        let ipv4 = NEIPv4Settings(addresses: [XrayTunnelLayout.ipv4Address], subnetMasks: [XrayTunnelLayout.ipv4SubnetMask])
        ipv4.includedRoutes = [NEIPv4Route.default()]
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: [XrayTunnelLayout.ipv6Address],
            networkPrefixLengths: [NSNumber(value: XrayTunnelLayout.ipv6PrefixLength)]
        )
        ipv6.includedRoutes = [NEIPv6Route.default()]
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: [XrayTunnelLayout.dnsServer])
        // Пустой match domain — этот резолвер обслуживает все домены.
        dns.matchDomains = [""]
        settings.dnsSettings = dns
        return settings
    }

    // MARK: - Сеть

    /// Записывает в диагностику смену сети (Wi-Fi ↔ сотовая). Xray сам переустанавливает
    /// соединения; заранее разрешённый IP сервера от смены сети не зависит.
    private func startPathMonitor() {
        pathMonitor?.cancel()
        let monitor = NWPathMonitor()
        let last = PathDescription()
        let store = diagnostics
        monitor.pathUpdateHandler = { path in
            let kind = [NWInterface.InterfaceType.wifi, .cellular, .wiredEthernet]
                .first { path.usesInterfaceType($0) }
                .map { "\($0)" } ?? "other"
            let description = "\(path.status) \(kind)"
            guard let previous = last.swap(description), previous != description else { return }
            store.update { $0.record("Сеть: \(description)") }
        }
        monitor.start(queue: DispatchQueue(label: "com.irklch.monovpn.path", qos: .utility))
        pathMonitor = monitor
    }

    /// IP-адрес ли строка.
    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }

    /// Разрешает имя сервера системным резолвером (до поднятия туннеля); IPv4 предпочтительнее.
    static func resolve(_ host: String) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_flags = AI_ADDRCONFIG
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var ipv4: String?
        var ipv6: String?
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(info.pointee.ai_addr, info.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: buffer)
                if info.pointee.ai_family == AF_INET, ipv4 == nil { ipv4 = text }
                if info.pointee.ai_family == AF_INET6, ipv6 == nil { ipv6 = text }
            }
            cursor = info.pointee.ai_next
        }
        return ipv4 ?? ipv6
    }

    /// Название причины остановки для диагностики.
    static func describe(_ reason: NEProviderStopReason) -> String {
        switch reason {
        case .none: "none"
        case .userInitiated: "userInitiated"
        case .providerFailed: "providerFailed"
        case .noNetworkAvailable: "noNetworkAvailable"
        case .unrecoverableNetworkChange: "unrecoverableNetworkChange"
        case .providerDisabled: "providerDisabled"
        case .authenticationCanceled: "authenticationCanceled"
        case .configurationFailed: "configurationFailed"
        case .idleTimeout: "idleTimeout"
        case .configurationDisabled: "configurationDisabled"
        case .configurationRemoved: "configurationRemoved"
        case .superceded: "superceded"
        case .userLogout: "userLogout"
        case .userSwitch: "userSwitch"
        case .connectionFailed: "connectionFailed"
        case .sleep: "sleep"
        case .appUpdate: "appUpdate"
        @unknown default: "unknown(\(reason.rawValue))"
        }
    }
}

/// Последнее описание сетевого пути; обработчик `NWPathMonitor` вызывается на его очереди.
private final class PathDescription: @unchecked Sendable {
    /// Защищает значение.
    private let lock = NSLock()
    /// Последнее описание.
    private var value: String?

    /// Записывает новое описание и возвращает прежнее; `nil` при первом вызове.
    func swap(_ newValue: String) -> String? {
        lock.withLock {
            defer { value = newValue }
            return value
        }
    }
}
#endif
