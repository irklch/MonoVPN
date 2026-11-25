import Foundation
import Libbox
import Network
import NetworkExtension
import os

/// Bridges sing-box (Libbox) to NetworkExtension: creates the TUN interface with the
/// routes and DNS requested by the core and reports network path changes.
///
/// Modelled on `ExtensionPlatformInterface` of sing-box-for-apple (GPL-3.0), reduced
/// to what Mono VPN needs. Features that do not apply to an iOS packet tunnel
/// (shell, SSH, bridges, process lookup) report "unsupported" errors to the core.
final class TunnelPlatformInterface: NSObject, LibboxPlatformInterfaceProtocol, LibboxCommandServerHandlerProtocol {
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Platform")

    private weak var provider: PacketTunnelProvider?
    private var networkSettings: NEPacketTunnelNetworkSettings?
    private var pathMonitor: NWPathMonitor?
    private var lastNetworkPath: String?
    private let lock = NSLock()

    init(provider: PacketTunnelProvider) {
        self.provider = provider
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        networkSettings = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
    }

    // MARK: - TUN

    func openTun(_ options: (any LibboxTunOptionsProtocol)?, ret0_: UnsafeMutablePointer<Int32>?) throws {
        try runBlocking { [self] in
            try await openTunAsync(options, ret0_)
        }
    }

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

        // IPv6: routed into the tunnel as well, so IPv6 traffic cannot bypass the VPN.
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

        // DNS: all queries go to the TUN DNS address, where sing-box hijacks them.
        if !dnsServers.isEmpty {
            let dns = NEDNSSettings(servers: dnsServers)
            let hasDefaultRoute = ipv4Routes.contains {
                $0.destinationAddress == "0.0.0.0" && $0.destinationSubnetMask == "0.0.0.0"
            }
            // Empty match domain = this resolver handles every domain.
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

    // MARK: - Network monitoring

    func usePlatformAutoDetectControl() -> Bool {
        false
    }

    func autoDetectControl(_: Int32) throws {}

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

    func closeDefaultInterfaceMonitor(_: (any LibboxInterfaceUpdateListenerProtocol)?) throws {
        lock.lock()
        defer { lock.unlock() }
        pathMonitor?.cancel()
        pathMonitor = nil
        lastNetworkPath = nil
    }

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

    func underNetworkExtension() -> Bool {
        true
    }

    func includeAllNetworks() -> Bool {
        provider?.protocolConfiguration.includeAllNetworks ?? false
    }

    func clearDNSCache() {
        lock.lock()
        let settings = networkSettings
        lock.unlock()
        guard let settings, let provider else { return }
        // Re-applying the settings flushes the system DNS cache.
        runBlocking {
            provider.reasserting = true
            defer { provider.reasserting = false }
            try? await provider.setTunnelNetworkSettings(nil)
            try? await provider.setTunnelNetworkSettings(settings)
        }
    }

    func readWIFIState() -> LibboxWIFIState? {
        // Reading the SSID needs location permission; Mono VPN has no Wi-Fi rules.
        nil
    }

    func localDNSTransport() -> (any LibboxLocalDNSTransportProtocol)? {
        nil
    }

    // MARK: - Unsupported platform features

    func findConnectionOwner(_: Int32, sourceAddress _: String?, sourcePort _: Int32, destinationAddress _: String?, destinationPort _: Int32) throws -> LibboxConnectionOwner {
        throw Self.unsupported
    }

    func send(_: LibboxNotification?) throws {}

    func cancelNotification(_: String?, typeID _: Int32) throws {}

    func startNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func closeNeighborMonitor(_: (any LibboxNeighborUpdateListenerProtocol)?) throws {}

    func registerMyInterface(_: String?) {}

    func usePlatformShell() -> Bool {
        false
    }

    func checkPlatformShell() throws {
        throw Self.unsupported
    }

    func openShellSession(_: LibboxPlatformUser?, command _: String?, environ _: (any LibboxStringIteratorProtocol)?, term _: String?, rows _: Int32, cols _: Int32) throws -> any LibboxShellSessionProtocol {
        throw Self.unsupported
    }

    func lookupUser(_: String?) throws -> LibboxPlatformUser {
        throw Self.unsupported
    }

    func lookupSFTPServer(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.unsupported
        return ""
    }

    func readSystemSSHHostKey(_ error: NSErrorPointer) -> String {
        error?.pointee = Self.unsupported
        return ""
    }

    func tailscaleHostname() -> String {
        ""
    }

    func usePlatformBridge() -> Bool {
        false
    }

    func createBridge(_: LibboxBridgeOptions?) throws -> any LibboxBridgeSessionProtocol {
        throw Self.unsupported
    }

    // MARK: - LibboxCommandServerHandler

    func serviceStop() throws {
        provider?.serviceStopRequested()
    }

    func serviceReload() throws {
        // The configuration only changes from the app, which restarts the tunnel.
    }

    func getSystemProxyStatus() throws -> LibboxSystemProxyStatus {
        LibboxSystemProxyStatus()
    }

    func setSystemProxyEnabled(_: Bool) throws {}

    func triggerNativeCrash() throws {
        throw Self.unsupported
    }

    func writeDebugMessage(_: String?) {
        // Debug output of the core may contain addresses: intentionally not logged.
    }

    func connectSSHAgent(_: UnsafeMutablePointer<Int32>?) throws {
        throw Self.unsupported
    }

    // MARK: - Helpers

    private static var unsupported: NSError {
        error("not supported on iOS")
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "com.irklch.monovpn.tunnel", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    private static func forEach(_ iterator: (any LibboxRoutePrefixIteratorProtocol)?, _ body: (LibboxRoutePrefix) -> Void) {
        guard let iterator else { return }
        while iterator.hasNext() {
            if let prefix = iterator.next() {
                body(prefix)
            }
        }
    }

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

private final class NetworkInterfaceIterator: NSObject, LibboxNetworkInterfaceIteratorProtocol {
    private var iterator: IndexingIterator<[LibboxNetworkInterface]>
    private var nextValue: LibboxNetworkInterface?

    init(_ interfaces: [LibboxNetworkInterface]) {
        iterator = interfaces.makeIterator()
    }

    func hasNext() -> Bool {
        nextValue = iterator.next()
        return nextValue != nil
    }

    func next() -> LibboxNetworkInterface? {
        nextValue
    }
}

/// Runs async work from a synchronous Libbox callback (called on a Go thread).
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

private final class ResultBox<T>: @unchecked Sendable {
    var value: Result<T, Error>?
}
