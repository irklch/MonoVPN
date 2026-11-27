import Foundation

/// Идентификаторы, общие для приложения и расширения Packet Tunnel.
///
/// Значения приходят из `Config/Identifiers.xcconfig` через Info.plist каждого таргета,
/// поэтому менять их нужно ровно в одном месте.
enum AppIdentifiers {
    /// App Group, общая для приложения и расширения.
    static let appGroup: String = infoValue("MonoAppGroupIdentifier") ?? "group.com.irklch.monovpn"

    /// Bundle identifier расширения Packet Tunnel.
    static let tunnelBundleID: String = infoValue("MonoTunnelBundleIdentifier") ?? "com.irklch.monovpn.PacketTunnel"

    /// Группа доступа Keychain, общая для обоих таргетов (возможность Keychain Sharing).
    ///
    /// Возвращает `nil` в сборках без подписи, где `$(AppIdentifierPrefix)` пуст и
    /// группа не может существовать; тогда используется стандартный (свой для приложения) Keychain.
    static let keychainAccessGroup: String? = {
        guard let group = infoValue("MonoKeychainAccessGroup") else { return nil }
        // В подписанной сборке значение вида "<TEAMID>.com.irklch.monovpn.shared".
        let parts = group.split(separator: ".", maxSplits: 1)
        guard let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
            return nil
        }
        return group
    }()

    /// WidgetKit kind виджета подключения на домашнем экране.
    static let widgetKind = "com.irklch.monovpn.widget.connection"

    /// Subsystem для `os.Logger`.
    static let logSubsystem = "com.irklch.monovpn"

    /// Читает строку из Info.plist по ключу.
    ///
    /// Возвращает `nil`, если значения нет, оно пустое или содержит
    /// неподставленную переменную сборки `$(...)`, — тогда вызывающий берёт значение по умолчанию.
    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }
}

/// Ключи элементов, хранящихся в общем Keychain.
enum SecureStorageKey: String {
    /// URL подписки, разобранные серверы и выбранный сервер (JSON, только приложение).
    case appState = "app-state.v1"
    /// Готовая к запуску конфигурация Xray для выбранного сервера (приложение → расширение).
    case tunnelConfiguration = "tunnel-configuration.v1"
    /// Последняя ошибка запуска, о которой сообщило расширение (расширение → приложение).
    case lastTunnelError = "last-tunnel-error.v1"
    /// Последняя ошибка команды виджета (виджет → виджет/приложение); сбрасывается после успешного подключения.
    case widgetError = "widget-error.v1"
}
