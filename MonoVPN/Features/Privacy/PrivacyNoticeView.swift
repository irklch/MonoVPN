import SwiftUI

/// Local privacy notice shown once, before the first connection.
struct PrivacyNoticeView: View {
    let onAccept: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(title: "privacy.title") {
                EmptyView()
            }

            VStack(alignment: .leading, spacing: 22) {
                item("shield", "privacy.item.client")
                item("arrow.triangle.branch", "privacy.item.traffic")
                item("eye.slash", "privacy.item.noTracking")
                item("key", "privacy.item.storage")
            }

            Spacer(minLength: 24)

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
