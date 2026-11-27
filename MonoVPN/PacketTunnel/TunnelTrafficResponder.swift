import Foundation

/// Отвечает приложению на запрос счётчиков трафика (`TunnelProviderMessage.trafficRequest`).
///
/// Имя интерфейса utun ищется один раз (`TunnelFileDescriptor`) и кэшируется до остановки
/// туннеля. Сообщения NetworkExtension приходят на произвольной очереди, поэтому состояние
/// защищено блокировкой.
final class TunnelTrafficResponder: @unchecked Sendable {
    private let lock = NSLock()
    private var interfaceName: String?

    /// Запоминает интерфейс туннеля (если он уже известен при запуске).
    func setInterfaceName(_ name: String?) {
        lock.withLock { interfaceName = name }
    }

    /// Ответ на сообщение приложения или `nil` для неизвестных сообщений.
    func response(to message: Data) -> Data? {
        guard message == TunnelProviderMessage.trafficRequest else { return nil }
        let name: String? = lock.withLock {
            if interfaceName == nil {
                interfaceName = TunnelFileDescriptor.find()?.interfaceName
            }
            return interfaceName
        }
        guard let name, let snapshot = InterfaceTrafficCounter.read(interfaceName: name) else { return nil }
        return try? JSONEncoder().encode(snapshot)
    }
}
