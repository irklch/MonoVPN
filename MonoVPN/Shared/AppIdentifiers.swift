import Foundation

/// Identifiers shared by the app and the Packet Tunnel extension.
///
/// Values come from `Config/Identifiers.xcconfig` through each target's Info.plist,
/// so there is exactly one place to change them.
enum AppIdentifiers {
    /// App Group shared by the app and the extension.
    static let appGroup: String = infoValue("MonoAppGroupIdentifier") ?? "group.com.irklch.monovpn"

    /// Bundle identifier of the Packet Tunnel extension.
    static let tunnelBundleID: String = infoValue("MonoTunnelBundleIdentifier") ?? "com.irklch.monovpn.PacketTunnel"

    /// Keychain access group shared by both targets (Keychain Sharing capability).
    ///
    /// Returns `nil` in unsigned builds, where `$(AppIdentifierPrefix)` is empty and the
    /// group cannot exist; the default (per-app) keychain is used then.
    static let keychainAccessGroup: String? = {
        guard let group = infoValue("MonoKeychainAccessGroup") else { return nil }
        // A signed build has "<TEAMID>.com.irklch.monovpn.shared".
        let parts = group.split(separator: ".", maxSplits: 1)
        guard let first = parts.first, first.count == 10, first.allSatisfy({ $0.isUppercase || $0.isNumber }) else {
            return nil
        }
        return group
    }()

    /// WidgetKit kind of the Home Screen connection widget.
    static let widgetKind = "com.irklch.monovpn.widget.connection"

    /// Subsystem for `os.Logger`.
    static let logSubsystem = "com.irklch.monovpn"

    private static func infoValue(_ key: String) -> String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty, !value.contains("$(") else {
            return nil
        }
        return value
    }
}

/// Keys of items stored in the shared Keychain.
enum SecureStorageKey: String {
    /// Subscription URL, parsed servers and selected server (JSON, app only).
    case appState = "app-state.v1"
    /// Ready-to-run sing-box configuration of the selected server (app → extension).
    case tunnelConfiguration = "tunnel-configuration.v1"
    /// Last start error reported by the extension (extension → app).
    case lastTunnelError = "last-tunnel-error.v1"
}
