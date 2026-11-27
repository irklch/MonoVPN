import SwiftUI

/// Окно подписки: добавление или замена, обновление и удаление подписки.
struct SubscriptionView: View {
    /// Модель главного экрана, через которую идут все действия с подпиской.
    let model: HomeViewModel
    /// Закрывает окно после сохранения или удаления.
    @Environment(\.dismiss) private var dismiss
    /// Текст в поле ввода: URL подписки или прокси-ссылка.
    @State private var input = ""
    /// Показан ли диалог подтверждения удаления.
    @State private var isDeleteConfirmationPresented = false
    /// Показано ли окно диагностики импорта.
    @State private var isDiagnosticsPresented = false
    /// Есть ли диагностика расширения Packet Tunnel (туннель хотя бы раз запускался).
    @State private var hasTunnelDiagnostics = false
    /// Фокус поля ввода; снимается перед сохранением, чтобы скрыть клавиатуру.
    @FocusState private var isFieldFocused: Bool

    /// Карточка текущей подписки, поле ввода, ошибка, кнопки и ссылка на диагностику импорта.
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "subscription.title") {
                    EmptyView()
                }

                if let subscription = model.subscription {
                    CurrentSubscriptionCard(subscription: subscription)
                        .padding(.bottom, 28)
                }

                inputSection

                if let error = model.subscriptionError {
                    NoticeText(systemName: "exclamationmark.circle", text: error)
                        .padding(.top, 14)
                }

                VStack(spacing: 12) {
                    Button {
                        Task { await save() }
                    } label: {
                        if model.isImporting {
                            ProgressView().tint(Mono.Palette.onPrimary)
                        } else {
                            Text("subscription.save")
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isImporting)

                    if let subscription = model.subscription {
                        if subscription.isRefreshable {
                            Button {
                                Task { await model.refreshSubscription() }
                            } label: {
                                if model.isRefreshing {
                                    ProgressView().tint(Mono.Palette.primary)
                                } else {
                                    Label("subscription.refresh", systemImage: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(model.isRefreshing || model.isImporting)
                        }

                        Button(role: .destructive) {
                            isDeleteConfirmationPresented = true
                        } label: {
                            Text("subscription.delete")
                                .font(.body.weight(.medium))
                                .foregroundStyle(Mono.Palette.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 24)

                if let subscription = model.subscription {
                    let count = ImportDiagnostics.entries(for: subscription).count
                    if count > 0 || !(model.appState.refreshReports ?? []).isEmpty || hasTunnelDiagnostics {
                        Button {
                            isDiagnosticsPresented = true
                        } label: {
                            Text("diagnostics.open \(count)")
                                .font(.footnote)
                                .foregroundStyle(Mono.Palette.secondary)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 8)
                    }
                }
            }
            .padding(.horizontal, Mono.Metrics.screenPadding)
            .padding(.bottom, 32)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear { hasTunnelDiagnostics = TunnelDiagnosticsStore().load().startedAt != nil }
        .background(Mono.Palette.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .sheet(isPresented: $isDiagnosticsPresented) {
            if let subscription = model.subscription {
                ImportDiagnosticsView(subscription: subscription, reports: model.appState.refreshReports ?? [])
            }
        }
        .confirmationDialog(
            "subscription.delete.title",
            isPresented: $isDeleteConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("subscription.delete.confirm", role: .destructive) {
                Task {
                    await model.deleteSubscription()
                    dismiss()
                }
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("subscription.delete.message")
        }
    }

    /// Поле ввода URL или ссылки с кнопкой вставки из буфера обмена и подсказкой.
    private var inputSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.subscription == nil ? "subscription.input.label.new" : "subscription.input.label.replace")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Mono.Palette.secondary)

            HStack(spacing: 10) {
                TextField("subscription.input.placeholder", text: $input, axis: .vertical)
                    .lineLimit(1...4)
                    .font(.body)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .focused($isFieldFocused)
                    .privacySensitive()

                PasteButton(payloadType: String.self) { strings in
                    if let value = strings.first {
                        input = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                .tint(Mono.Palette.primary)
                .accessibilityLabel(Text("subscription.paste"))
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .frame(minHeight: Mono.Metrics.controlHeight)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Mono.Palette.fill))

            Text("subscription.input.hint")
                .font(.caption)
                .foregroundStyle(Mono.Palette.secondary)
        }
    }

    /// Импортирует введённую подписку; при успехе очищает поле и закрывает окно.
    private func save() async {
        isFieldFocused = false
        if await model.importSubscription(from: input) {
            input = ""
            dismiss()
        }
    }
}

/// Краткие сведения о текущей подписке. Сам URL никогда не показывается: в нём может быть токен.
private struct CurrentSubscriptionCard: View {
    /// Текущая подписка.
    let subscription: Subscription

    /// Замаскированный источник, количество серверов и дата последнего обновления.
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .font(.system(size: 15, weight: .semibold))
                Text(subscription.maskedSource)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .foregroundStyle(Mono.Palette.primary)

            Text("subscription.servers.count \(subscription.servers.count)")
                .font(.subheadline)
                .foregroundStyle(Mono.Palette.secondary)

            Text("subscription.updated \(subscription.lastUpdated.formatted(date: .abbreviated, time: .shortened))")
                .font(.subheadline)
                .foregroundStyle(Mono.Palette.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(RoundedRectangle(cornerRadius: Mono.Metrics.cornerRadius, style: .continuous).fill(Mono.Palette.fill))
    }
}
