import AppIntents
import WidgetKit

/// Подключает или отключает VPN по нажатию на виджет, не открывая приложение.
///
/// Файл входит и в приложение, и в расширение виджета. Соответствие `LiveActivityIntent`
/// заставляет систему выполнять `perform()` в процессе приложения (запуская его в фоне),
/// а не в процессе виджета: управлять конфигурацией VPN через NetworkExtension надёжно
/// может только приложение, а из виджета нажатие приводило лишь к открытию приложения.
///
/// Направление фиксируется при отрисовке виджета, а `TunnelCommand.action` перепроверяет
/// реальный статус, поэтому двойное нажатие не может переключить VPN обратно.
struct ToggleVPNIntent: LiveActivityIntent {
    /// Название интента (системе нужно, пользователю не показывается).
    static let title: LocalizedStringResource = "widget.intent.title"
    /// Скрывает интент из Команд и Spotlight — он нужен только виджету.
    static let isDiscoverable = false
    /// Никогда не выводить приложение на передний план: VPN включается в фоне.
    static let openAppWhenRun = false

    /// iOS 26+: явный фоновый режим. Без него система может выполнять интент
    /// с открытием приложения (быстрый тап по виджету открывал приложение и не включал VPN).
    @available(iOS 26.0, *)
    static var supportedModes: IntentModes { .background }

    /// `true` — подключить, `false` — отключить.
    @Parameter(title: "widget.intent.connect")
    var connect: Bool

    /// Пустой инициализатор, которого требует `AppIntent`; по умолчанию — подключение.
    init() {
        connect = true
    }

    /// Создаёт интент с заданным направлением.
    init(connect: Bool) {
        self.connect = connect
    }

    /// Выполняет команду (последний выбранный сервер берётся из общего Keychain)
    /// и просит виджет перерисоваться с новым статусом.
    func perform() async throws -> some IntentResult {
        await WidgetCommandRunner.perform(connect ? .connect : .disconnect)
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
        return .result()
    }
}
