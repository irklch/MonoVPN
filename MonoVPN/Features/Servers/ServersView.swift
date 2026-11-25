import SwiftUI

/// Окно выбора сервера из текущей подписки.
struct ServersView: View {
    /// Модель главного экрана: список серверов, выбор и обновление подписки.
    let model: HomeViewModel
    /// Закрывает окно после выбора сервера.
    @Environment(\.dismiss) private var dismiss

    /// Заголовок с кнопкой обновления, ошибка и список серверов или пустое состояние.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "servers.title") {
                if model.subscription?.isRefreshable == true {
                    IconButton(
                        systemName: "arrow.clockwise",
                        accessibilityLabel: "servers.refresh",
                        isLoading: model.isRefreshing
                    ) {
                        Task { await model.refreshSubscription() }
                    }
                    .disabled(model.isRefreshing)
                }
            }
            .padding(.horizontal, Mono.Metrics.screenPadding)

            if let error = model.subscriptionError {
                NoticeText(systemName: "exclamationmark.circle", text: error)
                    .padding(.horizontal, Mono.Metrics.screenPadding)
                    .padding(.bottom, 12)
            }

            if model.servers.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .background(Mono.Palette.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// Прокручиваемый список всех распознанных серверов с разделителями.
    /// Неподдерживаемые ядром серверы показаны неактивными; подробности — в диагностике импорта.
    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.servers) { server in
                    ServerRow(server: server, isSelected: server.id == model.selectedServer?.id) {
                        Task {
                            await model.select(server)
                        }
                        dismiss()
                    }
                    .disabled(model.isBusy || !server.isSupported)
                    if server.id != model.servers.last?.id {
                        Divider().overlay(Mono.Palette.separator)
                    }
                }
            }
            .padding(.horizontal, Mono.Metrics.screenPadding)
            .padding(.bottom, 32)
        }
    }

    /// Пустое состояние, когда в подписке нет серверов.
    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Mono.Palette.tertiary)
            Text("servers.empty.title")
                .font(.headline)
                .foregroundStyle(Mono.Palette.primary)
            Text("servers.empty.message")
                .font(.subheadline)
                .foregroundStyle(Mono.Palette.secondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 40)
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
            .padding(.vertical, 16)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
