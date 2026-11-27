import SwiftUI

/// Локальное уведомление о конфиденциальности, показываемое один раз перед первым подключением.
struct PrivacyNoticeView: View {
    /// Вызывается, когда пользователь принял уведомление.
    let onAccept: () -> Void
    /// Закрывает окно по кнопке «Отмена».
    @Environment(\.dismiss) private var dismiss

    /// Заголовок, четыре пункта о том, как приложение обращается с данными, и кнопки принять / отмена.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "privacy.title") {
                EmptyView()
            }

            // Пункты прокручиваются, если не помещаются (маленький экран, крупный шрифт);
            // кнопки при этом остаются внизу, как и раньше.
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    item("shield", "privacy.item.client")
                    item("arrow.triangle.branch", "privacy.item.traffic")
                    item("eye.slash", "privacy.item.noTracking")
                    item("key", "privacy.item.storage")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)

            VStack(spacing: 12) {
                Button("privacy.accept", action: onAccept)
                    .buttonStyle(PrimaryButtonStyle())
                Button("common.cancel") { dismiss() }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .padding(.horizontal, Mono.Metrics.screenPadding)
        .padding(.bottom, 16)
        .background(Mono.Palette.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .interactiveDismissDisabled(false)
    }

    /// Один пункт уведомления: иконка SF Symbols и текст.
    private func item(_ systemName: String, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Mono.Palette.primary)
                .frame(width: 26)
            Text(text)
                .font(.body)
                .foregroundStyle(Mono.Palette.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
