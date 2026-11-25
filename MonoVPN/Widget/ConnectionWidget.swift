import AppIntents
import SwiftUI
import WidgetKit

/// Точка входа расширения виджетов: регистрирует виджеты Mono VPN.
@main
struct MonoVPNWidgetBundle: WidgetBundle {
    /// Набор виджетов расширения — сейчас только виджет подключения.
    var body: some Widget {
        ConnectionWidget()
    }
}

/// Маленький виджет домашнего экрана с одной кнопкой питания.
struct ConnectionWidget: Widget {
    /// Статическая конфигурация виджета размера small с названием и описанием для галереи.
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentifiers.widgetKind, provider: ConnectionProvider()) { entry in
            ConnectionWidgetView(state: entry.state)
        }
        .configurationDisplayName(Text("widget.displayName"))
        .description(Text("widget.description"))
        .supportedFamilies([.systemSmall])
    }
}

/// Запись таймлайна виджета.
struct ConnectionEntry: TimelineEntry {
    /// Момент, с которого запись показывается.
    let date: Date
    /// Состояние VPN для отображения.
    let state: WidgetVPNState
}

/// Читает реальный `NEVPNStatus` при каждой перезагрузке. Без опроса: перезагрузку запрашивают
/// приложение, Packet Tunnel и App Intent при смене статуса; только во время перехода
/// планируется одна дополнительная перезагрузка.
struct ConnectionProvider: TimelineProvider {
    /// Заглушка, пока виджет загружается: состояние «отключено».
    func placeholder(in _: Context) -> ConnectionEntry {
        ConnectionEntry(date: .now, state: .disconnected)
    }

    /// Снимок для галереи виджетов (статичный) или текущее состояние для домашнего экрана.
    func getSnapshot(in context: Context, completion: @escaping (ConnectionEntry) -> Void) {
        if context.isPreview {
            completion(ConnectionEntry(date: .now, state: .disconnected))
            return
        }
        Task {
            completion(ConnectionEntry(date: .now, state: await WidgetCommandRunner.currentState()))
        }
    }

    /// Таймлайн из одной записи; при переходном состоянии — повторная перезагрузка через 5 секунд, иначе никогда.
    func getTimeline(in _: Context, completion: @escaping (Timeline<ConnectionEntry>) -> Void) {
        Task {
            let state = await WidgetCommandRunner.currentState()
            let policy: TimelineReloadPolicy = state.isTransitioning ? .after(.now.addingTimeInterval(5)) : .never
            completion(Timeline(entries: [ConnectionEntry(date: .now, state: state)], policy: policy))
        }
    }
}

/// Подключает или отключает VPN из виджета — в процессе расширения виджета,
/// не открывая приложение. Направление фиксируется при отрисовке виджета,
/// а `TunnelCommand.action` перепроверяет реальный статус, поэтому двойное нажатие
/// не может переключить VPN обратно.
struct ToggleVPNIntent: AppIntent {
    /// Название интента (системе нужно, пользователю не показывается).
    static let title: LocalizedStringResource = "widget.intent.title"
    /// Скрывает интент из Команд и Spotlight — он нужен только виджету.
    static let isDiscoverable = false

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

    /// Выполняет команду и просит виджет перерисоваться с новым статусом.
    func perform() async throws -> some IntentResult {
        await WidgetCommandRunner.perform(connect ? .connect : .disconnect)
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
        return .result()
    }
}

/// Внешний вид виджета: кнопка питания и строка статуса на тёмном фоне.
struct ConnectionWidgetView: View {
    /// Отображаемое состояние VPN.
    let state: WidgetVPNState
    /// Режим отрисовки (полноцветный, тонированный и т. п.) — влияет на цвета кнопки.
    @Environment(\.widgetRenderingMode) private var renderingMode

    /// Тёмный фон виджета (#171717).
    private static let background = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255)

    /// Кнопка, статус и, для состояний `needsSetup`/`unavailable`, URL открытия приложения.
    var body: some View {
        VStack(spacing: 12) {
            control
            Text(statusKey)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(state == .connected ? .white : .white.opacity(0.55))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .invalidatableContent()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(for: .widget) {
            Self.background
        }
        // Системную конфигурацию VPN можно создать только в приложении (оно показывает
        // запрос разрешения). Маленький виджет поддерживает один URL на весь виджет,
        // поэтому в этом состоянии нажатие открывает приложение с явной командой «connect».
        // То же для `unavailable`: процесс виджета не смог прочитать конфигурацию VPN,
        // поэтому управление безопасно передаётся основному приложению.
        .widgetURL(state.opensApp ? TunnelCommand.connect.url : nil)
    }

    /// Кнопка с интентом в интерактивных состояниях; в остальных — просто картинка кнопки.
    @ViewBuilder
    private var control: some View {
        switch state {
        case .disconnected, .failed:
            Button(intent: ToggleVPNIntent(connect: true)) { powerButton }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("widget.button.connect"))
        case .connected, .connecting:
            Button(intent: ToggleVPNIntent(connect: false)) { powerButton }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("widget.button.disconnect"))
        case .needsSetup, .unavailable, .noServer, .disconnecting:
            powerButton
        }
    }

    /// Круглая кнопка питания: белая при подключении, приглушённая без сервера и во время перехода.
    private var powerButton: some View {
        let isOn = state == .connected
        let isDimmed = state == .noServer || state == .unavailable || state.isTransitioning
        return ZStack {
            Circle()
                .fill(isOn ? Color.white : Color.white.opacity(fullColor ? 0.1 : 0.2))
                .widgetAccentable()
            Image(systemName: "power")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(isOn && fullColor ? Self.background : Color.white)
                .opacity(isDimmed ? 0.45 : 1)
        }
        .frame(width: 76, height: 76)
        .invalidatableContent()
    }

    /// Виджет отрисовывается в полном цвете (не тонирован системой).
    private var fullColor: Bool {
        renderingMode == .fullColor
    }

    /// Ключ локализации строки статуса.
    private var statusKey: LocalizedStringKey {
        switch state {
        case .noServer: "widget.status.noServer"
        case .needsSetup: "widget.status.needsSetup"
        case .unavailable: "widget.status.unavailable"
        case .disconnected: "widget.status.disconnected"
        case .connecting: "widget.status.connecting"
        case .connected: "widget.status.connected"
        case .disconnecting: "widget.status.disconnecting"
        case .failed: "widget.status.failed"
        }
    }
}

#Preview(as: .systemSmall) {
    ConnectionWidget()
} timeline: {
    ConnectionEntry(date: .now, state: .disconnected)
    ConnectionEntry(date: .now, state: .connecting)
    ConnectionEntry(date: .now, state: .connected)
    ConnectionEntry(date: .now, state: .noServer)
    ConnectionEntry(date: .now, state: .failed)
    ConnectionEntry(date: .now, state: .unavailable)
}
