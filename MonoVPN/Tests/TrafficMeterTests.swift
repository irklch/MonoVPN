import Foundation
@testable import MonoVPN
import Testing

/// Тесты скорости трафика туннеля и признака «нет ответа от сервера».
struct TrafficMeterTests {
    @Test func rateIsBytesPerSecond() {
        let rate = TunnelTrafficRate(
            from: TunnelTrafficSnapshot(received: 1000, sent: 500),
            to: TunnelTrafficSnapshot(received: 5000, sent: 1500),
            interval: 2
        )
        #expect(rate == TunnelTrafficRate(received: 2000, sent: 500))
    }

    @Test func zeroIntervalGivesZeroRate() {
        let snapshot = TunnelTrafficSnapshot(received: 10, sent: 10)
        #expect(TunnelTrafficRate(from: snapshot, to: snapshot, interval: 0) == .zero)
    }

    @Test func deltaHandles32BitWrap() {
        let old = UInt64(UInt32.max) - 99
        #expect(TunnelTrafficRate.delta(old, 50) == 150)
    }

    @Test func deltaIsZeroWhenCounterReset() {
        // Счётчик больше 32 бит не может переполниться так: считаем, что туннель пересоздан.
        #expect(TunnelTrafficRate.delta(UInt64(UInt32.max) + 10, 5) == 0)
    }

    @Test func snapshotRoundTripsThroughJSON() throws {
        let snapshot = TunnelTrafficSnapshot(received: 123, sent: 456)
        let data = try JSONEncoder().encode(snapshot)
        #expect(try JSONDecoder().decode(TunnelTrafficSnapshot.self, from: data) == snapshot)
    }

    @Test func stallNeedsTimeAndSentData() {
        let start = Date(timeIntervalSince1970: 0)
        let detector = TrafficStallDetector(baseline: TunnelTrafficSnapshot(received: 0, sent: 0), startedAt: start)
        let noReply = TunnelTrafficSnapshot(received: 100, sent: 20_000)

        #expect(!detector.isStalled(current: noReply, at: start.addingTimeInterval(2)))
        #expect(detector.isStalled(current: noReply, at: start.addingTimeInterval(6)))
        // Почти ничего не отправлено — оценивать нечего.
        #expect(!detector.isStalled(current: TunnelTrafficSnapshot(received: 0, sent: 100), at: start.addingTimeInterval(6)))
        // Ответы приходят — всё в порядке.
        #expect(!detector.isStalled(current: TunnelTrafficSnapshot(received: 50_000, sent: 20_000), at: start.addingTimeInterval(6)))
    }

    @Test func speedFormatterShowsZeroNumerically() {
        let text = TrafficSpeedFormatter.string(bytesPerSecond: 0)
        #expect(text.contains("0"))
    }
}
