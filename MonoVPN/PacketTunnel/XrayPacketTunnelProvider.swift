import Foundation
import NetworkExtension
import os
import WidgetKit

/// Системный VPN-туннель на ядре Xray-core (libXray).
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
///
/// Расширение не ведёт журналов и не пишет диагностику на устройство: журналы Xray выключены
/// в самой конфигурации (`XrayConfigurationPolicy`), а технические сообщения `os.Logger`
/// есть только в DEBUG-сборке и не содержат адресов, ссылок и учётных данных.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    #if DEBUG
    /// Логгер категории «PacketTunnel» (только DEBUG); без адресов и секретов.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "PacketTunnel")
    #endif

    /// Keychain с конфигурацией туннеля и последней ошибкой запуска.
    private let storage = SecureStorage()
    /// Работает ли ядро, запущенное этим провайдером.
    private var isCoreRunning = false
    /// Счётчики трафика для главного экрана приложения.
    private let traffic = TunnelTrafficResponder()

    // MARK: - Жизненный цикл

    /// Поднимает туннель и запускает Xray; при ошибке сохраняет очищенный текст для приложения
    /// и виджета, освобождает ресурсы и пробрасывает ошибку системе.
    override func startTunnel(options _: [String: NSObject]?) async throws {
        try? storage.remove(.lastTunnelError)
        do {
            try await startTunnelAndCore()
            #if DEBUG
            Self.logger.debug("Tunnel started")
            #endif
            reloadWidget()
        } catch {
            // Очищенный текст ошибки нужен приложению и виджету, чтобы показать её пользователю.
            let message = TunnelErrorSanitizer.sanitize((error as NSError).localizedDescription)
            try? storage.set(message, for: .lastTunnelError)
            #if DEBUG
            Self.logger.error("Tunnel start failed: \(message, privacy: .private)")
            #endif
            stopCore()
            reloadWidget()
            throw TunnelError.core(message)
        }
    }

    /// Вызывается системой при остановке туннеля: останавливает ядро и обновляет виджет.
    override func stopTunnel(with reason: NEProviderStopReason) async {
        #if DEBUG
        Self.logger.debug("Stopping tunnel, reason \(reason.rawValue, privacy: .public)")
        #endif
        stopCore()
        traffic.setInterfaceName(nil)
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

        // 2. Адреса серверов — до сетевых настроек туннеля. У конфига из JSON-подписки
        // с балансировщиком их десятки: разрешаются параллельно, с общим ограничением времени.
        let hosts = try XrayRuntimeConfiguration.serverHosts(in: template)
        // Неразрешённые за отведённое время имена Xray разрешит сам при подключении.
        let resolved = Self.resolveAll(hosts, timeout: Self.resolveTimeout)

        // 3. Сетевые настройки туннеля.
        try await setTunnelNetworkSettings(Self.networkSettings())

        // 4. Дескриптор utun.
        guard let tun = TunnelFileDescriptor.find() else {
            throw TunnelError.core("TUN file descriptor not found")
        }
        traffic.setInterfaceName(tun.interfaceName)
        // Подготовка заново применяет `XrayConfigurationPolicy`: журналы выключены, а конфигурация
        // с Lua-скриптом (например, сохранённая прежней версией приложения) не запускается.
        let configuration = try XrayRuntimeConfiguration.prepare(
            template,
            tunFileDescriptor: tun.fd,
            resolvedAddresses: resolved
        )

        // 5. Ядро.
        try XrayCore.run(configuration: configuration)
        isCoreRunning = true
    }

    /// Останавливает Xray; безопасно вызывать повторно.
    private func stopCore() {
        guard isCoreRunning || XrayCore.isRunning() else { return }
        do {
            try XrayCore.stop()
        } catch {
            #if DEBUG
            Self.logger.error("Core stop failed")
            #endif
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

    /// IP-адрес ли строка.
    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        var ipv6 = in6_addr()
        return inet_pton(AF_INET, host, &ipv4) == 1 || inet_pton(AF_INET6, host, &ipv6) == 1
    }

    /// Общее ограничение времени на разрешение имён серверов перед запуском.
    static let resolveTimeout: TimeInterval = 5
    /// Сколько имён разрешается одновременно.
    static let resolveConcurrency = 16

    /// Разрешает имена параллельно (не больше `resolveConcurrency` сразу) и возвращает то,
    /// что успело разрешиться за `timeout`; остальные потоки дорабатывают в фоне.
    static func resolveAll(_ hosts: [String], timeout: TimeInterval) -> [String: String] {
        guard !hosts.isEmpty else { return [:] }
        if hosts.count == 1 {
            return resolve(hosts[0]).map { [hosts[0]: $0] } ?? [:]
        }
        let state = ResolveState(hosts: hosts)
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.irklch.monovpn.resolve", qos: .userInitiated, attributes: .concurrent)
        for _ in 0..<min(resolveConcurrency, hosts.count) {
            group.enter()
            queue.async {
                defer { group.leave() }
                while let host = state.next() {
                    if let ip = resolve(host) {
                        state.store(ip, for: host)
                    }
                }
            }
        }
        _ = group.wait(timeout: .now() + timeout)
        return state.snapshot()
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
}

/// Общая очередь имён и результаты для `resolveAll`.
private final class ResolveState: @unchecked Sendable {
    private let lock = NSLock()
    private let hosts: [String]
    private var index = 0
    private var results: [String: String] = [:]

    init(hosts: [String]) {
        self.hosts = hosts
    }

    /// Следующее имя или `nil`, если все разобраны.
    func next() -> String? {
        lock.withLock {
            guard index < hosts.count else { return nil }
            defer { index += 1 }
            return hosts[index]
        }
    }

    /// Сохраняет IP для имени.
    func store(_ ip: String, for host: String) {
        lock.withLock { results[host] = ip }
    }

    /// Копия результатов на текущий момент.
    func snapshot() -> [String: String] {
        lock.withLock { results }
    }
}
