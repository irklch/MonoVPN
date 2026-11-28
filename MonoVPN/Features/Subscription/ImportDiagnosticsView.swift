import SwiftUI

/// Одна запись диагностики импорта: имя сервера (если есть) и причина.
struct ImportDiagnosticEntry: Hashable {
    /// Раздел, к которому относится запись.
    enum Kind: Hashable, CaseIterable {
        /// Сервер распознан, но подключённое ядро (Xray-core) его не поддерживает.
        case unsupported
        /// Запись подписки не распознана (битая ссылка или неизвестная схема).
        case skipped
        /// Сервер поддерживается, но часть безвредных параметров не применена.
        case ignoredParameters
    }

    /// Раздел записи.
    let kind: Kind
    /// Имя сервера из ссылки; `nil`, если его нет.
    let name: String?
    /// Причина простым текстом.
    let detail: String
}

/// Собирает подробную диагностику импорта из сохранённой подписки.
///
/// В записи попадают только имена серверов из ссылок, названия протоколов/транспортов
/// и имена параметров — без UUID, паролей, токенов, значений параметров и URL подписки.
enum ImportDiagnostics {
    /// Все записи диагностики: неподдерживаемые, нераспознанные, с неприменёнными параметрами.
    static func entries(for subscription: Subscription) -> [ImportDiagnosticEntry] {
        var entries: [ImportDiagnosticEntry] = []
        for server in subscription.servers {
            if let incompatibility = server.incompatibility {
                entries.append(.init(kind: .unsupported, name: server.name, detail: incompatibility.localizedDescription))
            } else if !server.ignoredParameters.isEmpty {
                let keys = server.ignoredParameters.joined(separator: ", ")
                entries.append(.init(kind: .ignoredParameters, name: server.name, detail: String(localized: "diagnostics.ignored \(keys)")))
            }
        }
        for issue in subscription.issues {
            entries.append(.init(kind: .skipped, name: issue.name, detail: issue.reason))
        }
        return entries
    }
}

/// Окно с причинами, по которым часть серверов подписки недоступна или применена не полностью.
///
/// Показывает только то, что сохранено в подписке (`ImportDiagnostics.entries`): имена серверов,
/// названия протоколов/транспортов и имена параметров. Журналы, сведения о работе туннеля
/// и история обновлений не собираются и не показываются.
struct ImportDiagnosticsView: View {
    /// Подписка, для которой показываются причины.
    let subscription: Subscription

    /// Заголовок и записи по разделам, без ограничения количества.
    var body: some View {
        let entries = ImportDiagnostics.entries(for: subscription)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "diagnostics.title") {
                    EmptyView()
                }
                ForEach(ImportDiagnosticEntry.Kind.allCases, id: \.self) { kind in
                    let section = entries.filter { $0.kind == kind }
                    if !section.isEmpty {
                        Text(title(for: kind, count: section.count))
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(Mono.Palette.secondary)
                            .padding(.top, 8)
                            .padding(.bottom, 6)
                        ForEach(Array(section.enumerated()), id: \.offset) { _, entry in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: entry.name ?? "—")
                                    .font(.subheadline)
                                    .foregroundStyle(Mono.Palette.primary)
                                Text(verbatim: entry.detail)
                                    .font(.caption)
                                    .foregroundStyle(Mono.Palette.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 8)
                        }
                        .padding(.bottom, 12)
                    }
                }
            }
            .padding(.horizontal, Mono.Metrics.screenPadding)
            .padding(.bottom, 32)
        }
        .background(Mono.Palette.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    /// Заголовок раздела с количеством записей.
    private func title(for kind: ImportDiagnosticEntry.Kind, count: Int) -> LocalizedStringKey {
        switch kind {
        case .unsupported: "diagnostics.section.unsupported \(count)"
        case .skipped: "diagnostics.section.skipped \(count)"
        case .ignoredParameters: "diagnostics.section.ignored \(count)"
        }
    }
}
