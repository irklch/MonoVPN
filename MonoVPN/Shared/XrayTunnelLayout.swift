import Foundation

/// Общий контракт между приложением (генератор конфигурации Xray) и расширением Packet Tunnel.
///
/// Приложение пишет конфигурацию Xray в Keychain с заглушкой вместо файлового дескриптора
/// TUN; расширение настраивает интерфейс по этим же адресам, подставляет дескриптор и,
/// если адрес сервера — имя, заранее разрешённый IP. Значения не секретны.
enum XrayTunnelLayout {
    /// IPv4-адрес интерфейса туннеля.
    static let ipv4Address = "172.19.0.1"
    /// Маска IPv4-подсети туннеля (/30).
    static let ipv4SubnetMask = "255.255.255.252"
    /// DNS-сервер внутри туннеля: запросы на порт 53 перехватывает Xray (`dns-out`).
    /// Адрес в подсети туннеля, поэтому запросы к нему всегда попадают в TUN.
    static let dnsServer = "172.19.0.2"
    /// IPv6-адрес интерфейса туннеля (ULA).
    static let ipv6Address = "fdfe:dcba:9876::1"
    /// Длина префикса IPv6-подсети туннеля.
    static let ipv6PrefixLength = 126
    /// MTU интерфейса. Совпадает с `mtu` TUN inbound Xray; 1500 — значение по умолчанию Xray,
    /// пакеты помещаются в его буферы без фрагментации.
    static let mtu = 1500

    /// Ключ корневого объекта `env` конфигурации, из которого Xray берёт дескриптор TUN на iOS
    /// (`common/platform.TunFdKey`, `proxy/tun/tun_darwin.go`).
    static let tunFdEnvKey = "xray.tun.fd"
    /// Заглушка дескриптора в конфигурации из приложения; расширение заменяет её настоящим.
    static let tunFdPlaceholder = "-1"
    /// Тег TUN inbound.
    static let tunInboundTag = "tun-in"
    /// Тег исходящего соединения через прокси (всегда первый outbound).
    static let proxyOutboundTag = "proxy"
}
