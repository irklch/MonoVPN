import Foundation

/// Formats the connection duration as `HH:mm:ss`.
///
/// The value is always derived from the session start date (`connectedDate`), never
/// accumulated by a timer, so it stays correct after backgrounding or relaunch.
enum ConnectionDurationFormatter {
    static let zero = "00:00:00"

    static func string(from start: Date?, to now: Date) -> String {
        guard let start else { return zero }
        return string(seconds: now.timeIntervalSince(start))
    }

    static func string(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return zero }
        let total = Int(seconds.rounded(.down))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
}
