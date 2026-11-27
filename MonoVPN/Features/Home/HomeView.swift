import SwiftUI

/// Главный экран: статус и счётчик времени, большая кнопка подключения и список серверов.
///
/// Верхняя часть (статус, счётчик, кнопка) не прокручивается; ниже — список серверов
/// примерно на половину экрана, который прокручивается отдельно и при появлении
/// показывает выбранный сервер.
struct HomeView: View {
    /// Модель главного экрана.
    @Bindable var model: HomeViewModel
    /// Открыто ли окно подписки.
    @State private var isSubscriptionPresented = false

    /// Вёрстка экрана и модальные окна подписки и уведомления о конфиденциальности.
    var body: some View {
        VStack(spacing: 0) {
            // Неподвижная часть: не прокручивается вместе со списком.
            VStack(spacing: 0) {
                header
                ConnectionStatusView(state: model.state, connectedDate: model.vpn.connectedDate, hasServer: model.selectedServer != nil)
                    .padding(.top, 12)
                TrafficMeterView(vpn: model.vpn)
                    .padding(.top, 10)
                ConnectButton(
                    state: model.state,
                    isBusy: model.isBusy,
                    isEnabled: model.canToggleConnection
                ) {
                    Task { await model.toggleConnection() }
                }
                .padding(.top, 20)
                caption
                    .padding(.top, 16)
            }
            .padding(.horizontal, Mono.Metrics.screenPadding)
            // Список серверов занимает всё оставшееся место (примерно половину экрана).
            // Он на всю ширину экрана, чтобы индикатор прокрутки был у края экрана;
            // отступы задаёт сам список.
            serverArea
                .padding(.top, 12)
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(.bottom, 12)
        .background(Mono.Palette.background.ignoresSafeArea())
        .animation(Mono.Animation.state, value: model.state)
        .animation(Mono.Animation.state, value: model.selectedServer?.id)
        .sheet(isPresented: $isSubscriptionPresented) {
            SubscriptionView(model: model)
        }
        .sheet(isPresented: $model.isPrivacyNoticePresented) {
            PrivacyNoticeView {
                Task { await model.acceptPrivacyNotice() }
            }
        }
    }

    /// Заголовок с названием приложения и кнопкой подписки («+», если подписки нет).
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

    /// Подсказка под кнопкой и, если есть, ошибка подключения.
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

    /// Ключ локализации подсказки в зависимости от наличия сервера и состояния VPN.
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

    /// Нижняя часть: список серверов или, без подписки, кнопка её добавления.
    @ViewBuilder
    private var serverArea: some View {
        if model.subscription != nil {
            ServerListView(model: model)
                .transition(.opacity)
        } else {
            Button("home.addSubscription") {
                isSubscriptionPresented = true
            }
            .buttonStyle(PrimaryButtonStyle())
            .padding(.horizontal, Mono.Metrics.screenPadding)
            .transition(.opacity)
        }
    }
}

/// Строка статуса и крупный счётчик длительности.
private struct ConnectionStatusView: View {
    /// Состояние подключения.
    let state: VPNConnectionState
    /// Начало сессии; от него считается длительность.
    let connectedDate: Date?
    /// Выбран ли сервер — влияет на текст для состояния `.invalid`.
    let hasServer: Bool

    /// Точка и текст статуса над счётчиком, который обновляется раз в секунду.
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

    /// Ключ локализации текста статуса.
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

/// Большая круглая чёрная кнопка Play / Stop.
private struct ConnectButton: View {
    /// Состояние подключения — определяет иконку.
    let state: VPNConnectionState
    /// Идёт действие — вместо иконки показывается индикатор.
    let isBusy: Bool
    /// Доступна ли кнопка для нажатия.
    let isEnabled: Bool
    /// Действие по нажатию.
    let action: () -> Void

    /// Круг с иконкой или индикатором, тактильный отклик и подпись для VoiceOver.
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

/// Стиль кнопки, слегка уменьшающий её при нажатии.
private struct PressScaleStyle: ButtonStyle {
    /// Масштабирует метку до 95 % при нажатии с пружинной анимацией.
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.7), value: configuration.isPressed)
    }
}
