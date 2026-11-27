import SwiftUI

/// Список серверов текущей подписки на главном экране.
///
/// Прокручивается только сам список; при появлении он прокручивается к выбранному серверу,
/// чтобы быстро переключаться между соседними серверами. Нажатие выбирает сервер (при включённом
/// VPN — переподключает туннель). Неподдерживаемые ядром серверы показаны неактивными.
struct ServerListView: View {
    /// Модель главного экрана: список серверов, выбор и обновление подписки.
    let model: HomeViewModel

    /// Заголовок с кнопкой обновления, ошибка подписки и прокручиваемый список.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if let error = model.subscriptionError {
                NoticeText(systemName: "exclamationmark.circle", text: error)
                    .padding(.bottom, 10)
            }
            Divider().overlay(Mono.Palette.separator)
            if model.servers.isEmpty {
                emptyState
            } else {
                list
            }
        }
    }

    /// «Серверы · N» и кнопка обновления подписки.
    private var header: some View {
        HStack(spacing: 12) {
            Text("servers.title")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(1.2)
                .foregroundStyle(Mono.Palette.secondary)
                .accessibilityAddTraits(.isHeader)
            if !model.servers.isEmpty {
                Text(verbatim: "\(model.servers.count)")
                    .font(.footnote.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(Mono.Palette.tertiary)
            }
            Spacer(minLength: 8)
            if model.subscription?.isRefreshable == true {
                IconButton(
                    systemName: "arrow.clockwise",
                    accessibilityLabel: "servers.refresh",
                    isLoading: model.isRefreshing
                ) {
                    Task { await model.refreshSubscription() }
                }
                .disabled(model.isRefreshing || model.isImporting)
            }
        }
        .padding(.bottom, 8)
    }

    /// Прокручиваемые строки серверов с разделителями.
    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.servers) { server in
                        ServerRow(server: server, isSelected: server.id == model.selectedServer?.id) {
                            Task { await model.select(server) }
                        }
                        .disabled(model.isBusy || !server.isSupported)
                        .id(server.id)
                        if server.id != model.servers.last?.id {
                            Divider().overlay(Mono.Palette.separator)
                        }
                    }
                }
            }
            .onAppear { scrollToSelection(proxy, animated: false) }
            // После обновления подписки порядок и состав могут измениться.
            .onChange(of: model.subscription?.lastUpdated) { scrollToSelection(proxy, animated: true) }
        }
    }

    /// Прокручивает список так, чтобы выбранный сервер оказался по центру.
    private func scrollToSelection(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let id = model.selectedServer?.id else { return }
        // Ждём первую раскладку: ленивый список должен знать свои размеры.
        Task { @MainActor in
            if animated {
                withAnimation(Mono.Animation.state) { proxy.scrollTo(id, anchor: .center) }
            } else {
                proxy.scrollTo(id, anchor: .center)
            }
        }
    }

    /// Пустое состояние, когда в подписке нет серверов.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer(minLength: 0)
            Text("servers.empty.title")
                .font(.headline)
                .foregroundStyle(Mono.Palette.primary)
            Text("servers.empty.message")
                .font(.subheadline)
                .foregroundStyle(Mono.Palette.secondary)
                .multilineTextAlignment(.center)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Строка списка серверов: имя, протокол (или «Не поддерживается») и отметка выбора.
private struct ServerRow: View {
    /// Сервер этой строки.
    let server: ServerConfiguration
    /// Выбран ли сервер сейчас.
    let isSelected: Bool
    /// Действие по нажатию — выбрать сервер.
    let action: () -> Void

    /// Кнопка на всю ширину строки с текстом сервера и галочкой у выбранного.
    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(server.name)
                        .font(.body.weight(isSelected ? .semibold : .regular))
                        .foregroundStyle(server.isSupported ? Mono.Palette.primary : Mono.Palette.tertiary)
                        .lineLimit(2)
                    if server.isSupported {
                        Text(server.protocolSummary)
                            .font(.footnote)
                            .foregroundStyle(Mono.Palette.secondary)
                    } else {
                        Text("servers.unsupported \(server.protocolSummary)")
                            .font(.footnote)
                            .foregroundStyle(Mono.Palette.tertiary)
                    }
                }
                Spacer(minLength: 8)
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(Mono.Palette.primary)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
