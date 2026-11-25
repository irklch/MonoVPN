import Foundation
import Libbox
import Network
import NetworkExtension
import os

/// Связывает sing-box (Libbox) с NetworkExtension: создаёт TUN-интерфейс с маршрутами
/// и DNS, которые запросило ядро, и сообщает об изменениях сетевого пути.
///
/// Сделан по образцу `ExtensionPlatformInterface` из sing-box-for-apple (GPL-3.0) и сокращён
/// до того, что нужно Mono VPN. Возможности, неприменимые к packet tunnel на iOS
/// (shell, SSH, мосты, поиск процессов), возвращают ядру ошибку «не поддерживается».
final class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    /// Логгер категории «Platform».
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Platform")

    /// Провайдер туннеля; слабая ссылка, потому что провайдер владеет этим объектом.
    private weak var provider: PacketTunnelProvider?
    /// Последние применённые сетевые настройки; нужны для сброса DNS-кэша.
    private var networkSettings: NEPacketTunnelNetworkSettings?
    /// Монитор сетевого пути, пока ядро следит за интерфейсом по умолчанию.
    private var pathMonitor: NWPathMonitor?
    /// Описание последнего пути — чтобы сообщать ядру только о реальных изменениях.
    private var lastNetworkPath: String?
    /// Защищает изменяемое состояние: Libbox вызывает методы из разных потоков Go.
    private let lock = NSLock()

    /// Создаёт мост для данного провайдера туннеля.
    init(provider: PacketTunnelProvider) {
        self.provider = provider
    }

    /// Сбрасывает состояние после остановки ядра: настройки, монитор пути и последний путь.
    func reset() {
        lock.lock()
        defer { lock.unlock() }
        networkSettings = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
    }

    // MARK: - TUN

    /// Вызывается ядром синхронно: открывает TUN и возвращает его файловый дескриптор в `ret0_`.
    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTunAsync(options, ret0_)
        }
    }

    /// Строит `NEPacketTunnelNetworkSettings` из опций ядра (адреса, маршруты IPv4/IPv6, DNS, HTTP-прокси),
    /// применяет их и находит файловый дескриптор TUN.
    private func openTunAsync(_ options: (any LibboxTunOptionsProtocol)?, _ ret0_: UnsafeMutablePointer<Int32>?) async throws {
        guard let options, let ret0_ else { throw Self.error("missing TUN options") }
        guard let provider else { throw Self.error("tunnel provider released") }

        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        let autoRoute = options.getAutoRoute()
        let dnsMode = options.getDNSMode()?.value ?? ""

        var dnsServers: [String] = []
        if dnsMode != LibboxDNSModeDisabled, autoRoute || !dnsMode.isEmpty {
            let iterator = try options.getDNSServerAddress()
            while iterator.hasNext() {
                dnsServers.append(iterator.next())
            }
        }

        settings.mtu = NSNumber(value: options.getMTU())

        // IPv4
        var ipv4Addresses: [String] = []
        var ipv4Masks: [String] = []
        Self.forEach(options.getInet4Address()) {
            ipv4Addresses.append($0.address())
            ipv4Masks.append($0.mask())
        }
        var ipv4Routes: [NEIPv4Route] = []
        var ipv4Excluded: [NEIPv4Route] = []
        if autoRoute {
            Self.forEach(options.getInet4RouteAddress()) {
                ipv4Routes.append(NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask()))
            }
            if ipv4Routes.isEmpty {
                ipv4Routes.append(NEIPv4Route.default())
            }
        } else {
            for server in dnsServers where !server.contains(":") {
                ipv4Routes.append(NEIPv4Route(destinationAddress: server, subnetMask: "255.255.255.255"))
            }
        }
        Self.forEach(options.getInet4RouteExcludeAddress()) {
            ipv4Excluded.append(NEIPv4Route(destinationAddress: $0.address(), subnetMask: $0.mask()))
        }
        if !ipv4Addresses.isEmpty {
            let ipv4 = NEIPv4Settings(addresses: ipv4Addresses, subnetMasks: ipv4Masks)
            ipv4.includedRoutes = ipv4Routes
            ipv4.excludedRoutes = ipv4Excluded
            settings.ipv4Settings = ipv4
        }

        // IPv6: тоже направляется в туннель, чтобы трафик IPv6 не мог обойти VPN.
        var ipv6Addresses: [String] = []
        var ipv6Prefixes: [NSNumber] = []
        Self.forEach(options.getInet6Address()) {
            ipv6Addresses.append($0.address())
            ipv6Prefixes.append(NSNumber(value: $0.prefix()))
        }
        var ipv6Routes: [NEIPv6Route] = []
        var ipv6Excluded: [NEIPv6Route] = []
        if autoRoute {
            Self.forEach(options.getInet6RouteAddress()) {
                ipv6Routes.append(NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix())))
            }
            if ipv6Routes.isEmpty {
                ipv6Routes.append(NEIPv6Route.default())
            }
        } else {
            for server in dnsServers where server.contains(":") {
                ipv6Routes.append(NEIPv6Route(destinationAddress: server, networkPrefixLength: 128))
            }
        }
        Self.forEach(options.getInet6RouteExcludeAddress()) {
            ipv6Excluded.append(NEIPv6Route(destinationAddress: $0.address(), networkPrefixLength: NSNumber(value: $0.prefix())))
        }
        if !ipv6Addresses.isEmpty {
            let ipv6 = NEIPv6Settings(addresses: ipv6Addresses, networkPrefixLengths: ipv6Prefixes)
            ipv6.includedRoutes = ipv6Routes
            ipv6.excludedRoutes = ipv6Excluded
            settings.ipv6Settings = ipv6
        }

        // DNS: все запросы идут на DNS-адрес TUN, где sing-box их перехватывает.
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            let hasDefaultRoute = ipv4Routes.contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            // Пустой match domain = этот резолвер обслуживает все домены.
            dns.matchDomains = [""]
            if !hasDefaultRoute {
                dns.matchDomainsNoSearch = true
            }
            settings.dnsSettings = dns
        }

        if options.isHTTPProxyEnabled() {
            let proxy = NEProxySettings()
            let server = NEProxyServer(address: options.getHTTPProxyServer(), port: Int(options.getHTTPProxyServerPort()))
            proxy.httpServer = server
            proxy.httpsServer = server
            proxy.httpEnabled = true
            proxy.httpsEnabled = true
            settings.proxySettings = proxy
        }

        lock.withLock { networkSettings = settings }
        try await provider.setTunnelNetworkSettings(settings)

        if let fd = provider.packetFlow.value(forKeyPath: "socket.fileDescriptor") as? Int32 {
            ret0_.pointee = fd
            return
        }
        let fd = LibboxGetTunnelFileDescriptor()
        guard fd != -1 else { throw Self.error("missing TUN file descriptor") }
        ret0_.pointee = fd
    }

    // MARK: - Мониторинг сети

    /// Платформенный контроль сокетов не используется — в Network Extension он не нужен.
    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    /// Привязка сокета к интерфейсу; на iOS ничего не делает.
    func autoDetectControl(_: Int32) throws {}

    /// Запускает `NWPathMonitor` и сообщает ядру об интерфейсе по умолчанию.
    ///
    /// Блокируется до первого обновления пути, чтобы ядро стартовало уже с известной сетью.
    func startDefaultInterfaceMonitor(_ listener: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        guard let listener else { return }
        let monitor = NWPathMonitor()
        lock.lock()
        pathMonitor = monitor
        lock.unlock()

        let semaphore = DispatchSemaphore(value: 0)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.updateDefaultInterface(listener, path)
            semaphore.signal()
            monitor.pathUpdateHandler = { [weak self] path in
                self?.updateDefaultInterface(listener, path)
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.irklch.monovpn.path-monitor"))
        semaphore.wait()
    }

    /// Передаёт ядру описание пути и, если путь изменился, — новый интерфейс по умолчанию
    /// (или его отсутствие, когда сети нет).
    private func updateDefaultInterface(_ listener: any LibboxInterfaceUpdateListenerProtocol, _ path: Network.NWPath) {
        let description = Self.describe(path)
        listener.updateNetworkPath(description)
        lock.lock()
        let changed = description != lastNetworkPath
        lastNetworkPath = description
        lock.unlock()
        guard changed else { return }

        guard path.status != .unsatisfied, let interface = path.availableInterfaces.first else {
            listener.updateDefaultInterface("", interfaceIndex: -1, isExpensive: false, isConstrained: false)
            return
        }
        listener.updateDefaultInterface(
            interface.name,
            interfaceIndex: Int32(interface.index),
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    /// Останавливает монитор сетевого пути.
    func closeDefaultInterfaceMonitor(_: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        lock.lock()
        defer { lock.unlock() }
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
    }

    /// Список доступных сетевых интерфейсов с их типами (Wi-Fi, сотовая, Ethernet).
    func getInterfaces() throws -> any LibboxNetworkInterfaceIteratorProtocol {
        lock.lock()
        let monitor = pathMonitor
        lock.unlock()
        guard let monitor else { throw Self.error("network monitor is not running") }
        let path = monitor.currentPath
        guard path.status != .unsatisfied else { return NetworkInterfaceIterator([]) }

        let interfaces = path.availableInterfaces.map { item -> LibboxNetworkInterface in
            let interface = LibboxNetworkInterface()
            interface.name = item.name
            interface.index = Int32(item.index)
            switch item.type {
            case .wifi: interface.type = LibboxInterfaceTypeWIFI
            case .cellular: interface.type = LibboxInterfaceTypeCellular
            case .wiredEthernet: interface.type = LibboxInterfaceTypeEthernet
            default: interface.type = LibboxInterfaceTypeOther
            }
            return interface
        }
        return NetworkInterfaceIterator(interfaces)
    }

    /// Сообщает ядру, что оно работает внутри Network Extension.
    func underNetworkExtension() -> Bool {
        true
    }

    /// Включён ли в конфигурации VPN режим `includeAllNetworks`.
    func includeAllNetworks() -> Bool {
        provider?.protocolConfiguration.includeAllNetworks ?? false
    }

    /// Сбрасывает системный DNS-кэш повторным применением сетевых настроек.
    func clearDNSCache() {
        lock.lock()
        let settings = networkSettings
        lock.unlock()
        guard let settings, let provider else { return }
        // Повторное применение настроек очищает системный DNS-кэш.
        runBlocking {
            provider.reasserting = true
            defer { provider.reasserting = false }
            try? await provider.setTunnelNetworkSettings(nil)
            try? await provider.setTunnelNetworkSettings(settings)
        }
    }

    /// Состояние Wi-Fi не читается.
    func readWIFIState() -> LibboxWIFIState? {
        // Для чтения SSID нужно разрешение на геолокацию; правил по Wi-Fi в Mono VPN нет.
        nil
    }

    /// Платформенный локальный DNS-транспорт не используется; ядро берёт свой.
    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    // MARK: - Неподдерживаемые возможности платформы

    /// Поиск процесса-владельца соединения; на iOS не поддерживается.
    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw Self.unsupported
    }

    /// Уведомления от ядра не показываются.
    func send(_: LibboxNotification?) throws {}

    /// Отмена уведомления; ничего не делает, потому что уведомления не показываются.
    func cancelNotification(_: String?, typeID _: Int32) throws {}

    /// Мониторинг соседей в сети не нужен; ничего не делает.
    func startNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    /// Остановка мониторинга соседей; ничего не делает.
    func closeNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    /// Регистрация собственного интерфейса; на iOS не нужна.
    func registerMyInterface(_: String?) {}

    /// Платформенный shell не используется.
    func usePlatformShell() -> Bool {
        false
    }

    /// Shell на iOS не поддерживается.
    func checkPlatformShell() throws {
        throw Self.unsupported
    }

    /// Shell-сессии на iOS не поддерживаются.
    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw Self.unsupported
    }

    /// Поиск пользователя системы на iOS не поддерживается.
    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw Self.unsupported
    }

    /// SFTP-сервер на iOS не поддерживается; возвращает ошибку через `error`.
    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.unsupported
        return ""
    }

    /// Ключ SSH-хоста на iOS недоступен; возвращает ошибку через `error`.
    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.unsupported
        return ""
    }

    /// Имя хоста Tailscale; Tailscale не используется.
    func tailscaleHostname() -> String {
        ""
    }

    /// Платформенные мосты не используются.
    func usePlatformBridge() -> Bool {
        false
    }

    /// Мосты на iOS не поддерживаются.
    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw Self.unsupported
    }

    // MARK: - LibboxCommandServerHandler

    /// Ядро просит остановить сервис — останавливаем туннель через провайдер.
    func serviceStop() throws {
        provider?.serviceStopRequested()
    }

    /// Перезагрузка сервиса по запросу ядра; ничего не делает.
    func serviceReload() throws {
        // Конфигурация меняется только из приложения, которое перезапускает туннель.
    }

    /// Статус системного прокси; он не используется, поэтому возвращается пустой статус.
    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    /// Включение системного прокси; не используется.
    func setSystemProxyEnabled(_: Bool) throws {}

    /// Отладочное аварийное завершение; на iOS не поддерживается.
    func triggerNativeCrash() throws {
        throw Self.unsupported
    }

    /// Отладочные сообщения ядра намеренно отбрасываются.
    func writeDebugMessage(_: String?) {
        // Отладочный вывод ядра может содержать адреса: намеренно не логируется.
    }

    /// SSH-агент на iOS не поддерживается.
    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw Self.unsupported
    }

    // MARK: - Вспомогательное

    /// Общая ошибка «не поддерживается на iOS».
    private static var unsupported: NSError {
        error("not supported on iOS")
    }

    /// Создаёт `NSError` домена туннеля с текстом для ядра.
    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.irklch.monovpn.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Проходит по итератору префиксов маршрутов Libbox, пропуская пустые значения.
    private static func forEach(_ iterator: (any LibboxRoutePrefixIteratorProtocol)?, _ body: (LibboxRoutePrefix) -> Void) {
        guard let iterator else { return }
        while iterator.hasNext() {
            if let prefix = iterator.next() {
                body(prefix)
            }
        }
    }

    /// Текстовое описание сетевого пути: статус, интерфейсы и флаги. Используется для обнаружения изменений.
    private static func describe(_ path: Network.NWPath) -> String {
        var parts: [String] = ["\(path.status)"]
        parts.append(path.availableInterfaces.map { "\($0.name)#\($0.index)" }.joined(separator: ","))
        if path.supportsIPv4 { parts.append("ipv4") }
        if path.supportsIPv6 { parts.append("ipv6") }
        if path.isExpensive { parts.append("expensive") }
        if path.isConstrained { parts.append("constrained") }
        return parts.joined(separator: " ")
    }
}

/// Итератор сетевых интерфейсов в формате, который ожидает Libbox (`hasNext` + `next`).
private final class NetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    /// Итератор по массиву интерфейсов.
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    /// Элемент, заранее прочитанный в `hasNext()` и отдаваемый в `next()`.
    private var nextValue: LibboxNetworkInterface?

    /// Создаёт итератор по готовому списку интерфейсов.
    init(_ interfaces: [LibboxNetworkInterface]) {
        iterator = interfaces.makeIterator()
    }

    /// Продвигается к следующему элементу и сообщает, есть ли он.
    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    /// Возвращает элемент, прочитанный последним вызовом `hasNext()`.
    func next() -> LibboxNetworkInterface? {
        nextValue
    }
}

/// Выполняет асинхронную работу из синхронного колбэка Libbox (вызывается в потоке Go).
func runBlocking<T>(_ body: @escaping () async -> T) -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        box.value = .success(await body())
        semaphore.signal()
    }
    semaphore.wait()
    guard case let .success(value)? = box.value else {
        preconditionFailure("runBlocking: the task finished without a value")
    }
    return value
}

/// Бросающий вариант `runBlocking`: ждёт результат асинхронной работы и пробрасывает её ошибку.
func runBlocking<T>(_ body: @escaping () async throws -> T) throws -> T {
    let semaphore = DispatchSemaphore(value: 0)
    let box = ResultBox<T>()
    Task.detached(priority: .userInitiated) {
        do {
            box.value = .success(try await body())
        } catch {
            box.value = .failure(error)
        }
        semaphore.signal()
    }
    semaphore.wait()
    guard let result = box.value else { throw CancellationError() }
    return try result.get()
}

/// Контейнер для передачи результата из отсоединённой задачи в ожидающий поток.
private final class ResultBox<T>: @unchecked Sendable {
    /// Результат задачи; `nil`, пока задача не завершилась.
    var value: Result<T, Error>?
}
