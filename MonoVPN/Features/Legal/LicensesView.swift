import SwiftUI

/// Лицензии и уведомления об авторских правах сторонних компонентов (Xray-core и его
/// зависимости, Go) со ссылками на исходный код использованных версий.
struct LicensesView: View {
    /// Уведомления из бандла (читаются один раз); `nil` — ресурс не загрузился.
    private static let notices = ThirdPartyNotices.load()
    /// Компоненты, у которых раскрыт текст лицензии.
    @State private var expanded: Set<String> = []

    /// Заголовок, пояснение и список компонентов; тексты лицензий раскрываются по нажатию.
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "licenses.title") {
                    EmptyView()
                }
                Text("licenses.intro")
                    .font(.subheadline)
                    .foregroundStyle(Mono.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 16)

                if let notices = Self.notices {
                    ForEach(notices.components) { component in
                        row(component)
                            .padding(.vertical, 12)
                        Divider().overlay(Mono.Palette.separator)
                    }
                } else {
                    NoticeText(systemName: "exclamationmark.circle", text: String(localized: "licenses.unavailable"))
                }
            }
            .padding(.horizontal, Mono.Metrics.screenPadding)
            .padding(.bottom, 32)
        }
        .background(Mono.Palette.background.ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// Компонент: название, версия и лицензия, ссылки на исходники, текст лицензии.
    private func row(_ component: ThirdPartyNotices.Component) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: component.name)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Mono.Palette.primary)
            Text(verbatim: "\(component.displayVersion ?? component.version) · \(component.license)")
                .font(.caption)
                .foregroundStyle(Mono.Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let url = URL(string: component.source) {
                Link(destination: url) {
                    Text("licenses.source")
                }
                .font(.caption)
            }
            if let url = URL(string: component.sourceArchive) {
                Link(destination: url) {
                    Text("licenses.archive")
                }
                .font(.caption)
            }
            ForEach(component.notes, id: \.self) { note in
                Text(verbatim: note)
                    .font(.caption)
                    .foregroundStyle(Mono.Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button {
                if expanded.contains(component.id) {
                    expanded.remove(component.id)
                } else {
                    expanded.insert(component.id)
                }
            } label: {
                Text(expanded.contains(component.id) ? "licenses.hideText" : "licenses.showText")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Mono.Palette.primary)
                    .frame(minHeight: 32)
            }
            .buttonStyle(.plain)
            if expanded.contains(component.id) {
                ForEach(component.texts, id: \.title) { document in
                    Text(verbatim: document.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Mono.Palette.secondary)
                        .padding(.top, 4)
                    Text(verbatim: document.text)
                        .font(.caption2.monospaced())
                        .foregroundStyle(Mono.Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
        .tint(Mono.Palette.primary)
    }
}
