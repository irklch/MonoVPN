import Darwin
import Foundation

/// Счётчики байт интерфейса туннеля (utun) с момента его создания.
///
/// Направления — с точки зрения пользователя:
/// - `sent` (исходящий) — пакеты, которые приложения отправили в туннель
///   (для utun это `ifi_obytes`: ядро «выводит» их в интерфейс, их читает ядро VPN);
/// - `received` (входящий) — пакеты, которые ядро VPN записало обратно в туннель
///   (`ifi_ibytes`): ответы серверов.
///
/// Если `sent` растёт, а `received` стоит на месте, приложения пытаются выйти в сеть,
/// но через сервер ничего не возвращается — VPN «подключён», но не работает.
struct TunnelTrafficSnapshot: Codable, Equatable, Sendable {
    /// Получено из туннеля, байт.
    var received: UInt64
    /// Отправлено в туннель, байт.
    var sent: UInt64
}

/// Скорость трафика в байтах в секунду.
struct TunnelTrafficRate: Equatable, Sendable {
    /// Входящая скорость.
    var received: Double
    /// Исходящая скорость.
    var sent: Double

    /// Нулевая скорость.
    static let zero = TunnelTrafficRate(received: 0, sent: 0)

    /// Скорость между двумя замерами, сделанными с интервалом `interval` секунд.
    ///
    /// Счётчики `if_data` на iOS 32-битные и переполняются после 4 ГБ: переполнение
    /// учитывается. Если счётчик уменьшился сильнее (туннель пересоздан), скорость — 0.
    init(from old: TunnelTrafficSnapshot, to new: TunnelTrafficSnapshot, interval: TimeInterval) {
        guard interval > 0 else {
            self = .zero
            return
        }
        received = Double(Self.delta(old.received, new.received)) / interval
        sent = Double(Self.delta(old.sent, new.sent)) / interval
    }

    /// Создаёт скорость из готовых значений.
    init(received: Double, sent: Double) {
        self.received = received
        self.sent = sent
    }

    /// Прирост счётчика с учётом переполнения 32-битного значения.
    static func delta(_ old: UInt64, _ new: UInt64) -> UInt64 {
        if new >= old { return new - old }
        let wrap = UInt64(UInt32.max) + 1
        guard old < wrap, new < wrap else { return 0 }
        return wrap - old + new
    }
}

/// Сообщения между приложением и расширением Packet Tunnel (`sendProviderMessage`).
enum TunnelProviderMessage {
    /// Запрос счётчиков трафика; ответ — JSON `TunnelTrafficSnapshot`.
    static let trafficRequest = Data("traffic".utf8)
}

/// Чтение счётчиков байт сетевого интерфейса через `getifaddrs` (публичный API).
enum InterfaceTrafficCounter {
    /// Счётчики интерфейса с именем `name` (например, `utun4`); `nil`, если его нет.
    static func read(interfaceName name: String) -> TunnelTrafficSnapshot? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            // Статистика интерфейса лежит в записи семейства AF_LINK.
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name) == name,
                  let data = entry.pointee.ifa_data else { continue }
            let stats = data.assumingMemoryBound(to: if_data.self).pointee
            return TunnelTrafficSnapshot(received: UInt64(stats.ifi_ibytes), sent: UInt64(stats.ifi_obytes))
        }
        return nil
    }
}
