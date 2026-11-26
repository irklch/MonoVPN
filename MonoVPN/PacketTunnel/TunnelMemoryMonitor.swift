import Darwin
import Foundation
import os

/// Периодически измеряет память расширения Packet Tunnel и записывает её в диагностику.
///
/// Измеряется `phys_footprint` (`task_info(TASK_VM_INFO)`) — именно эту величину iOS сравнивает
/// с лимитом памяти расширения (~50 МБ), — и остаток до лимита (`os_proc_available_memory`).
/// Сообщения системы о нехватке памяти (`DispatchSource.makeMemoryPressureSource`) записываются
/// событиями. Данные не содержат ничего, кроме чисел и времени.
final class TunnelMemoryMonitor: @unchecked Sendable {
    /// Логгер категории «Memory»: только числа.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "Memory")

    /// Интервал измерения.
    private let interval: DispatchTimeInterval
    /// Диагностика в App Group.
    private let store: TunnelDiagnosticsStore
    /// Очередь таймера и источника давления памяти.
    private let queue = DispatchQueue(label: "com.irklch.monovpn.memory", qos: .utility)
    /// Таймер измерений.
    private var timer: DispatchSourceTimer?
    /// Источник событий о нехватке памяти.
    private var pressureSource: DispatchSourceMemoryPressure?
    /// Пик за текущую сессию, байты.
    private var peak: UInt64 = 0
    /// Пик, записанный в файл последним; запись делается при росте пика на 1 МБ или раз в 30 с.
    private var lastSavedPeak: UInt64 = 0
    /// Время последней записи в файл.
    private var lastSave = Date.distantPast

    /// Создаёт монитор; интервал по умолчанию — 5 секунд.
    init(interval: DispatchTimeInterval = .seconds(5), store: TunnelDiagnosticsStore = TunnelDiagnosticsStore()) {
        self.interval = interval
        self.store = store
    }

    /// Текущий `phys_footprint` процесса в байтах; `nil`, если `task_info` не ответил.
    static func physFootprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.phys_footprint : nil
    }

    /// Начинает измерения с нуля (новая сессия туннеля).
    func start() {
        queue.async { [self] in
            stopSources()
            peak = 0
            lastSavedPeak = 0
            lastSave = .distantPast

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(1))
            timer.setEventHandler { [weak self] in self?.sample(force: false) }
            timer.resume()
            self.timer = timer

            let pressure = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: queue)
            pressure.setEventHandler { [weak self, weak pressure] in
                guard let self, let event = pressure?.data else { return }
                let level = event.contains(.critical) ? "critical" : "warning"
                Self.logger.warning("Memory pressure: \(level, privacy: .public)")
                self.sample(force: true, event: "Нехватка памяти: \(level)")
            }
            pressure.resume()
            pressureSource = pressure
        }
    }

    /// Останавливает измерения и записывает последнее значение.
    func stop() {
        queue.sync {
            sample(force: true)
            stopSources()
        }
    }

    /// Снимает таймер и источник давления памяти.
    private func stopSources() {
        timer?.cancel()
        timer = nil
        pressureSource?.cancel()
        pressureSource = nil
    }

    /// Измеряет память и при необходимости сохраняет её в диагностику.
    private func sample(force: Bool, event: String? = nil) {
        guard let footprint = Self.physFootprint() else { return }
        let available = UInt64(os_proc_available_memory())
        peak = max(peak, footprint)

        let now = Date()
        let peakGrew = peak >= lastSavedPeak + 1_048_576
        guard force || event != nil || peakGrew || now.timeIntervalSince(lastSave) >= 30 else { return }
        lastSave = now
        lastSavedPeak = peak

        let megabytes = { (bytes: UInt64) in (Double(bytes) / 1_048_576 * 10).rounded() / 10 }
        store.update { diagnostics in
            diagnostics.footprintMB = megabytes(footprint)
            diagnostics.peakFootprintMB = megabytes(peak)
            diagnostics.availableMB = megabytes(available)
            diagnostics.memorySampledAt = now
            if let event {
                diagnostics.record("\(event); память \(megabytes(footprint)) МБ, осталось \(megabytes(available)) МБ")
            }
        }
        Self.logger.info("""
            Memory footprint \(megabytes(footprint), privacy: .public) MB, \
            peak \(megabytes(self.peak), privacy: .public) MB, available \(megabytes(available), privacy: .public) MB
            """)
    }
}
