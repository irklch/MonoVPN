import SwiftUI

/// Скорость входящего и исходящего трафика туннеля под счётчиком времени.
///
/// Пока VPN подключён, раз в секунду запрашивает у расширения счётчики байт интерфейса
/// туннеля. Если в туннель уходят данные, а в ответ ничего не приходит, показывает
/// предупреждение: VPN «подключён», но через сервер сеть не работает.
struct TrafficMeterView: View {
    /// Менеджер VPN: источник счётчиков.
    let vpn: VPNManager

    /// Текущая скорость; `nil` — нет данных (не подключено или расширение не ответило).
    @State private var rate: TunnelTrafficRate?
    /// Нет ответа от сервера (см. `TrafficStallDetector`).
    @State private var isStalled = false

    /// Интервал опроса.
    private static let interval: Duration = .seconds(1)

    /// Две колонки «↓ входящий» и «↑ исходящий» и, при необходимости, предупреждение.
    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 24) {
                item(systemName: "arrow.down", value: rate?.received, label: "home.traffic.download.accessibility")
                item(systemName: "arrow.up", value: rate?.sent, label: "home.traffic.upload.accessibility")
            }
            if isStalled {
                NoticeText(systemName: "exclamationmark.triangle", text: String(localized: "home.traffic.noResponse"))
                    .transition(.opacity)
            }
        }
        .animation(Mono.Animation.state, value: isStalled)
        .task(id: vpn.state == .connected) {
            await monitor()
        }
    }

    /// Одна колонка: стрелка и скорость моноширинными цифрами.
    private func item(systemName: String, value: Double?, label: LocalizedStringKey) -> some View {
        HStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
            Text(value.map { TrafficSpeedFormatter.string(bytesPerSecond: $0) } ?? "—")
                .font(.footnote)
                .monospacedDigit()
                .contentTransition(.numericText())
        }
        .foregroundStyle(value == nil ? Mono.Palette.tertiary : Mono.Palette.secondary)
        .frame(minWidth: 110)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(value.map { TrafficSpeedFormatter.string(bytesPerSecond: $0) } ?? "—"))
    }

    /// Опрос счётчиков, пока VPN подключён; задача отменяется при смене состояния или уходе с экрана.
    private func monitor() async {
        rate = nil
        isStalled = false
        guard vpn.state == .connected else { return }

        var previous: (snapshot: TunnelTrafficSnapshot, date: Date)?
        var detector: TrafficStallDetector?
        while !Task.isCancelled {
            if let snapshot = await vpn.fetchTraffic() {
                let now = Date()
                if let previous {
                    rate = TunnelTrafficRate(from: previous.snapshot, to: snapshot, interval: now.timeIntervalSince(previous.date))
                } else {
                    rate = .zero
                }
                previous = (snapshot, now)
                if detector == nil {
                    detector = TrafficStallDetector(baseline: snapshot, startedAt: now)
                }
                isStalled = detector?.isStalled(current: snapshot, at: now) ?? false
            }
            try? await Task.sleep(for: Self.interval)
        }
    }
}
