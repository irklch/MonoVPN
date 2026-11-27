import Foundation

/// Форматирует длительность подключения как `HH:mm:ss`.
///
/// Значение всегда вычисляется от даты начала сессии (`connectedDate`), а не
/// накапливается таймером, поэтому остаётся верным после ухода в фон или перезапуска.
enum ConnectionDurationFormatter {
    /// Строка для нулевой длительности; показывается, когда VPN не подключён.
    static let zero = "00:00:00"

    /// Длительность от `start` до `now`; если даты начала нет — `zero`.
    static func string(from start: Date?, to now: Date) -> String {
        guard let start else { return zero }
        return string(seconds: now.timeIntervalSince(start))
    }

    /// Форматирует количество секунд как `HH:mm:ss`.
    ///
    /// Отрицательные, нулевые и нечисловые значения дают `zero`, дробная часть отбрасывается.
    static func string(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return zero }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
