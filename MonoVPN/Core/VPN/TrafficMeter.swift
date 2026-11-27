import Foundation

/// Форматирование скорости трафика для главного экрана: «0 байт/с», «12,3 КБ/с», «1,2 МБ/с».
enum TrafficSpeedFormatter {
    /// Строка скорости в локали пользователя.
    static func string(bytesPerSecond: Double) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useBytes, .useKB, .useMB, .useGB]
        // «0 байт», а не «Zero KB».
        formatter.allowsNonnumericFormatting = false
        let bytes = Int64(max(0, bytesPerSecond).rounded())
        return String(localized: "home.traffic.rate \(formatter.string(fromByteCount: bytes))")
    }
}

/// Признак «VPN подключён, но через сервер ничего не возвращается».
///
/// Сравнивает счётчики с первым замером после подключения: если за `minimumDuration`
/// приложения отправили в туннель заметный объём (`minimumSent`), а в ответ почти ничего
/// не пришло (меньше `maximumReceived`), сервер, скорее всего, не пропускает трафик.
struct TrafficStallDetector: Equatable, Sendable {
    /// Сколько секунд наблюдать, прежде чем делать вывод.
    static let minimumDuration: TimeInterval = 5
    /// Сколько байт должно уйти в туннель, чтобы было что оценивать.
    static let minimumSent: UInt64 = 4096
    /// Порог «почти ничего не пришло», байт.
    static let maximumReceived: UInt64 = 1024

    /// Первый замер.
    let baseline: TunnelTrafficSnapshot
    /// Время первого замера.
    let startedAt: Date

    /// Есть ли признаки того, что трафик через сервер не идёт.
    func isStalled(current: TunnelTrafficSnapshot, at now: Date) -> Bool {
        guard now.timeIntervalSince(startedAt) >= Self.minimumDuration else { return false }
        let sent = TunnelTrafficRate.delta(baseline.sent, current.sent)
        let received = TunnelTrafficRate.delta(baseline.received, current.received)
        return sent >= Self.minimumSent && received < Self.maximumReceived
    }
}
