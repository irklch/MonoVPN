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

    /// Прокручиваемый список серверов с разделителями и пропущенными записями в конце.
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
                    .disabled(model.isBusy)
                    if server.id != model.servers.last?.id {
                        Divider().overlay(Mono.Palette.separator)
                    }
                }
                if let issues = model.subscription?.issues, !issues.isEmpty {
                    SkippedServersNote(issues: issues)
                        .padding(.top, 20)
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

/// Строка списка серверов: имя, протокол, проигнорированные параметры и отметка выбора.
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
                        .foregroundStyle(Mono.Palette.primary)
                        .lineLimit(2)
                    Text(server.protocolSummary)
                        .font(.footnote)
                        .foregroundStyle(Mono.Palette.secondary)
                    if !server.ignoredParameters.isEmpty {
                        Text("servers.ignoredParameters \(server.ignoredParameters.joined(separator: ", "))")
                            .font(.caption)
                            .foregroundStyle(Mono.Palette.secondary)
                            .lineLimit(2)
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

/// Перечисляет записи подписки, которые не были импортированы, чтобы ничего не терялось молча.
struct SkippedServersNote: View {
    /// Пропущенные записи с причинами.
    let issues: [ParseIssue]

    /// Заголовок с количеством и до 10 записей вида «имя: причина».
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("servers.skipped \(issues.count)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Mono.Palette.secondary)
            ForEach(Array(issues.prefix(10).enumerated()), id: \.offset) { _, issue in
                Text(verbatim: "• \(issue.name ?? "—"): \(issue.reason)")
                    .font(.caption)
                    .foregroundStyle(Mono.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
