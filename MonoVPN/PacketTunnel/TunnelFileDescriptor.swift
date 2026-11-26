import Darwin
import Foundation

/// Поиск файлового дескриптора utun, который NetworkExtension открыл для этого расширения.
///
/// Используются только публичные системные вызовы: перебираются дескрипторы процесса и через
/// `getsockopt(fd, SYSPROTO_CONTROL, UTUN_OPT_IFNAME)` ищется сокет управления с именем `utunN`.
/// Так же дескриптор находит WireGuard для iOS и пример из `proxy/tun/README.md` Xray-core
/// (раздел iOS SUPPORT). Приватный KVC `packetFlow.socket.fileDescriptor` не используется.
enum TunnelFileDescriptor {
    /// `SYSPROTO_CONTROL` из `<sys/sys_domain.h>` (в iOS SDK не экспортируется в Swift).
    private static let sysprotoControl: Int32 = 2
    /// `UTUN_OPT_IFNAME` из `<net/if_utun.h>` (в iOS SDK не экспортируется в Swift).
    private static let utunOptIfname: Int32 = 2
    /// Верхняя граница перебора дескрипторов.
    private static let maxDescriptor: Int32 = 1024

    /// Найденный дескриптор и имя интерфейса.
    struct Match: Equatable {
        /// Номер дескриптора; остаётся во владении NetworkExtension (Xray работает с дубликатом).
        let fd: Int32
        /// Имя интерфейса, например `utun4`.
        let interfaceName: String
    }

    /// Первый дескриптор utun процесса или `nil`, если NetworkExtension ещё не создал интерфейс
    /// (до `setTunnelNetworkSettings`).
    static func find() -> Match? {
        var buffer = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        for fd in 0...maxDescriptor {
            var length = socklen_t(buffer.count)
            guard getsockopt(fd, sysprotoControl, utunOptIfname, &buffer, &length) == 0 else { continue }
            let name = String(cString: buffer)
            if name.hasPrefix("utun") {
                return Match(fd: fd, interfaceName: name)
            }
        }
        return nil
    }
}
