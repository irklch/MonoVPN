import AppIntents
import SwiftUI
import WidgetKit

@main
struct MonoVPNWidgetBundle: WidgetBundle {
    var body: some Widget {
        ConnectionWidget()
    }
}

/// Small Home Screen widget with a single power button.
struct ConnectionWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: AppIdentifiers.widgetKind, provider: ConnectionProvider()) { entry in
            ConnectionWidgetView(state: entry.state)
        }
        .configurationDisplayName(Text("widget.displayName"))
        .description(Text("widget.description"))
        .supportedFamilies([.systemSmall])
    }
}

struct ConnectionEntry: TimelineEntry {
    let date: Date
    let state: WidgetVPNState
}

/// Reads the real `NEVPNStatus` on every reload. No polling: reloads are requested by
/// the app, the Packet Tunnel and the App Intent when the status changes; only while
/// a transition is in progress a single follow-up reload is scheduled.
struct ConnectionProvider: TimelineProvider {
    func placeholder(in _: Context) -> ConnectionEntry {
        ConnectionEntry(date: .now, state: .disconnected)
    }

    func getSnapshot(in context: Context, completion: @escaping (ConnectionEntry) -> Void) {
        if context.isPreview {
            completion(ConnectionEntry(date: .now, state: .disconnected))
            return
        }
        Task {
            completion(ConnectionEntry(date: .now, state: await WidgetCommandRunner.currentState()))
        }
    }

    func getTimeline(in _: Context, completion: @escaping (Timeline<ConnectionEntry>) -> Void) {
        Task {
            let state = await WidgetCommandRunner.currentState()
            let policy: TimelineReloadPolicy = state.isTransitioning ? .after(.now.addingTimeInterval(5)) : .never
            completion(Timeline(entries: [ConnectionEntry(date: .now, state: state)], policy: policy))
        }
    }
}

/// Connects or disconnects the VPN from the widget, in the widget extension process,
/// without opening the app. The requested direction is fixed when the widget is
/// rendered, and `TunnelCommand.action` re-checks the real status, so a double tap
/// cannot toggle the VPN back.
struct ToggleVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "widget.intent.title"
    static let isDiscoverable = false

    @Parameter(title: "widget.intent.connect")
    var connect: Bool

    init() {
        connect = true
    }

    init(connect: Bool) {
        self.connect = connect
    }

    func perform() async throws -> some IntentResult {
        await WidgetCommandRunner.perform(connect ? .connect : .disconnect)
        WidgetCenter.shared.reloadTimelines(ofKind: AppIdentifiers.widgetKind)
        return .result()
    }
}

struct ConnectionWidgetView: View {
    let state: WidgetVPNState
    @Environment(\.widgetRenderingMode) private var renderingMode

    private static let background = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x17 / 255)

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
        // The system VPN configuration can only be created in the app (it shows a
        // permission prompt). A small widget supports one URL for the whole widget,
        // so in this state a tap opens the app with an explicit "connect" command.
        .widgetURL(state == .needsSetup ? TunnelCommand.connect.url : nil)
    }

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
        case .needsSetup, .noServer, .disconnecting:
            powerButton
        }
    }

    private var powerButton: some View {
        let isOn = state == .connected
        let isDimmed = state == .noServer || state.isTransitioning
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

    private var fullColor: Bool {
        renderingMode == .fullColor
    }

    private var statusKey: LocalizedStringKey {
        switch state {
        case .noServer: "widget.status.noServer"
        case .needsSetup, .disconnected: "widget.status.disconnected"
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
}
