import Foundation

/// VPN-ядро и его возможности: от них зависит, какие серверы подписки помечаются
/// «Не поддерживается».
///
/// Приложение работает только на Xray-core (libXray). Значение сохраняется вместе с подпиской
/// (`Subscription.core`), чтобы подписку, разобранную другим ядром, один раз обновить.
enum VPNCore: String, Codable, Sendable {
    /// sing-box — ядро сборок до 1.0.0. Встречается только в данных, сохранённых этими сборками:
    /// без этого значения такие подписки не декодировались бы. Такая подписка обновляется
    /// при запуске (`HomeViewModel.start`).
    case singBox = "sing-box"
    /// Xray-core (libXray).
    case xray = "xray"

    /// Ядро приложения.
    static let current: VPNCore = .xray

    /// Есть ли транспорт XHTTP (SplitHTTP).
    var supportsXHTTP: Bool { self == .xray }

    /// Есть ли `finalmask` Xray (параметр ссылки `fm`): фрагментация TLS ClientHello и
    /// другие маски поверх транспорта. В sing-box аналога нет — параметр не применяется.
    var supportsFinalMask: Bool { self == .xray }

    /// Можно ли задать gRPC `:authority` независимо от SNI.
    var supportsIndependentGRPCAuthority: Bool { self == .xray }

    /// Есть ли транспорт HTTP/2 (`type=http`/`h2`); в Xray-core он удалён.
    var supportsHTTP2Transport: Bool { self == .singBox }

    /// Есть ли SIP003-плагины Shadowsocks (`obfs-local`, `v2ray-plugin`); в Xray-core их нет.
    var supportsShadowsocksPlugins: Bool { self == .singBox }

    /// Шифры Shadowsocks, которые реализует ядро (`infra/conf/shadowsocks.go` для Xray).
    var shadowsocksMethods: Set<String> {
        var methods: Set<String> = [
            "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305",
            "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305", "xchacha20-ietf-poly1305",
        ]
        if self == .singBox {
            methods.insert("aes-192-gcm")
        }
        return methods
    }

    /// Vision (`xtls-rprx-vision`) на транспорте, отличном от TCP, отбрасывается, а не делает
    /// сервер неподдерживаемым. Xray-core выполняет Vision только поверх прямого TLS/REALITY
    /// (`proxy/vless/outbound`: «XTLS only supports TLS and REALITY directly»), и эталонные
    /// клиенты Xray не передают `flow` для gRPC/XHTTP/WS.
    var dropsFlowOnNonTCPTransport: Bool { self == .xray }
}
