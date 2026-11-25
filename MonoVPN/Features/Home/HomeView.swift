import SwiftUI

struct HomeView: View {
    @Bindable var model: HomeViewModel
    @State private var isSubscriptionPresented = false
    @State private var isServersPresented = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Spacer(minLength: 24)
            ConnectionStatusView(state: model.state, connectedDate: model.vpn.connectedDate, hasServer: model.selectedServer != nil)
            Spacer(minLength: 32)
            ConnectButton(
                state: model.state,
                isBusy: model.isBusy,
                isEnabled: model.canToggleConnection
            ) {
                Task { await model.toggleConnection() }
            }
            caption
                .padding(.top, 22)
            Spacer(minLength: 24)
            footer
        }
        .padding(.horizontal, Mono.Metrics.screenPadding)
        .padding(.bottom, 12)
        .background(Mono.Palette.background.ignoresSafeArea())
        .animation(Mono.Animation.state, value: model.state)
        .animation(Mono.Animation.state, value: model.selectedServer?.id)
        .sheet(isPresented: $isSubscriptionPresented) {
            SubscriptionView(model: model)
        }
        .sheet(isPresented: $isServersPresented) {
            ServersView(model: model)
        }
        .sheet(isPresented: $model.isPrivacyNoticePresented) {
            PrivacyNoticeView {
                Task { await model.acceptPrivacyNotice() }
            }
        }
    }

    private var header: some View {
        HStack {
            Text("app.title")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Mono.Palette.primary)
            Spacer()
            IconButton(
                systemName: model.subscription == nil ? "plus" : "link",
                accessibilityLabel: "home.subscription.accessibility"
            ) {
                isSubscriptionPresented = true
            }
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var caption: some View {
        VStack(spacing: 10) {
            Text(captionKey)
                .font(.subheadline)
                .foregroundStyle(Mono.Palette.secondary)
                .contentTransition(.opacity)
            if let error = model.visibleConnectionError {
                NoticeText(systemName: "exclamationmark.circle", text: error)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            }
        }
        .frame(minHeight: 44, alignment: .top)
    }

    private var captionKey: LocalizedStringKey {
        if model.selectedServer == nil {
            return "home.caption.noSubscription"
        }
        switch model.state {
        case .connected: return "home.caption.tapToDisconnect"
        case .connecting, .reasserting: return "home.caption.connecting"
        case .disconnecting: return "home.caption.disconnecting"
        case .disconnected, .invalid: return "home.caption.tapToConnect"
        }
    }

    @ViewBuilder
    private var footer: some View {
        if let server = model.selectedServer {
            ServerCard(server: server, isLocked: model.isBusy) {
                isServersPresented = true
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        } else {
            Button("home.addSubscription") {
                isSubscriptionPresented = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .transition(.opacity)
        }
    }
}

/// Status line and the large duration counter.
private struct ConnectionStatusView: View {
    let state: VPNConnectionState
    let connectedDate: Date?
    let hasServer: Bool

    var body: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state == .connected ? Mono.Palette.primary : Mono.Palette.tertiary)
                    .frame(width: 7, height: 7)
                Text(statusKey)
                    .font(.footnote.weight(.semibold))
                    .textCase(.uppercase)
                    .tracking(1.2)
                    .foregroundStyle(state == .connected ? Mono.Palette.primary : Mono.Palette.secondary)
                    .contentTransition(.opacity)
            }
            .accessibilityElement(children: .combine)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(ConnectionDurationFormatter.string(
                    from: state == .connected ? connectedDate : nil,
                    to: context.date
                ))
                .font(.system(size: 58, weight: .light))
                .monospacedDigit()
                .foregroundStyle(state == .connected ? Mono.Palette.primary : Mono.Palette.tertiary)
                .contentTransition(.numericText())
            }
            .accessibilityLabel(Text("home.duration.accessibility"))
        }
    }

    private var statusKey: LocalizedStringKey {
        switch state {
        case .invalid: hasServer ? "status.disconnected" : "status.notConfigured"
        case .disconnected: "status.disconnected"
        case .connecting: "status.connecting"
        case .connected: "status.connected"
        case .reasserting: "status.reasserting"
        case .disconnecting: "status.disconnecting"
        }
    }
}

/// Large round black Play / Stop button.
private struct ConnectButton: View {
    let state: VPNConnectionState
    let isBusy: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isEnabled || isBusy ? Mono.Palette.primary : Mono.Palette.tertiary)
                if isBusy {
                    ProgressView()
                        .controlSize(.large)
                        .tint(Mono.Palette.onPrimary)
                        .transition(.opacity)
                } else {
                    Image(systemName: state.isActive ? "stop.fill" : "play.fill")
                        .font(.system(size: 40, weight: .semibold))
                        .foregroundStyle(Mono.Palette.onPrimary)
                        .offset(x: state.isActive ? 0 : 3)
                        .contentTransition(.symbolEffect(.replace))
                        .transition(.opacity)
                }
            }
            .frame(width: Mono.Metrics.connectButtonSize, height: Mono.Metrics.connectButtonSize)
            .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .sensoryFeedback(.impact(weight: .medium), trigger: state.isActive)
        .accessibilityLabel(Text(state.isActive ? "home.button.disconnect" : "home.button.connect"))
    }
}

private struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Bottom card with the selected server.
private struct ServerCard: View {
    let server: ServerConfiguration
    let isLocked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Mono.Palette.primary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Mono.Palette.background))
                VStack(alignment: .leading, spacing: 3) {
                    Text(server.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Mono.Palette.primary)
                        .lineLimit(1)
                    Text(server.protocolSummary)
                        .font(.footnote)
                        .foregroundStyle(Mono.Palette.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Mono.Palette.secondary)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: Mono.Metrics.cornerRadius, style: .continuous).fill(Mono.Palette.fill))
            .contentShape(RoundedRectangle(cornerRadius: Mono.Metrics.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isLocked)
        .accessibilityHint(Text("home.serverCard.hint"))
    }
}
