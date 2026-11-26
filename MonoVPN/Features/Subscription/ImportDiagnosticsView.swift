import SwiftUI

/// Одна запись диагностики импорта: имя сервера (если есть) и причина.
struct ImportDiagnosticEntry: Hashable {
    /// Раздел, к которому относится запись.
    enum Kind: Hashable, CaseIterable {
        /// Сервер распознан, но подключённое ядро sing-box его не поддерживает.
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

/// Окно подробной диагностики импорта подписки — отдельно от основного списка серверов.
struct ImportDiagnosticsView: View {
    /// Подписка, для которой показывается диагностика.
    let subscription: Subscription
    /// Отчёты о последних обновлениях подписки, от старых к новым.
    var reports: [SubscriptionRefreshReport] = []

    /// Заголовок, отчёты об обновлениях и записи по разделам, без ограничения количества.
    var body: some View {
        let entries = ImportDiagnostics.entries(for: subscription)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                SheetHeader(title: "diagnostics.title") {
                    EmptyView()
                }
                if !reports.isEmpty {
                    Text("diagnostics.section.refreshes \(reports.count)")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Mono.Palette.secondary)
                        .padding(.top, 8)
                        .padding(.bottom, 6)
                    // Новые отчёты сверху.
                    ForEach(reports.reversed()) { report in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: report.date.formatted(date: .abbreviated, time: .standard))
                                .font(.subheadline)
                                .foregroundStyle(Mono.Palette.primary)
                            Text(verbatim: RefreshReportText.lines(for: report).joined(separator: "\n"))
                                .font(.caption)
                                .foregroundStyle(Mono.Palette.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 8)
                    }
                    .padding(.bottom, 12)
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

/// Текст отчёта об обновлении подписки: только счётчики, коды, хеш ответа и имена серверов.
enum RefreshReportText {
    /// Строки отчёта в порядке показа.
    static func lines(for report: SubscriptionRefreshReport) -> [String] {
        let format = SubscriptionDiagnostics.format
        var lines: [String] = []
        switch report.responseChange {
        case .first: lines.append(String(localized: "diagnostics.refresh.response.first"))
        case .identical: lines.append(String(localized: "diagnostics.refresh.response.identical"))
        case .reordered: lines.append(String(localized: "diagnostics.refresh.response.reordered"))
        case .changed: lines.append(String(localized: "diagnostics.refresh.response.changed"))
        }
        if report.indicatesAppBug {
            lines.append(String(localized: "diagnostics.refresh.appBug"))
        }
        lines.append(String(localized: "diagnostics.refresh.hash \(report.responseHash) \(report.byteCount)"))
        lines.append(String(localized: "diagnostics.refresh.counts \(report.total) \(report.supported) \(report.unsupported) \(report.invalid)"))
        if report.duplicateNames > 0 {
            lines.append(String(localized: "diagnostics.refresh.duplicateNames \(report.duplicateNames)"))
        }
        if report.responseChange != .first {
            lines.append(String(localized: "diagnostics.refresh.diff \(report.added) \(report.removed) \(report.changed)"))
        }
        lines.append(String(localized: "diagnostics.refresh.protocols \(format(report.protocols))"))
        lines.append(String(localized: "diagnostics.refresh.transports \(format(report.transports))"))
        lines.append(String(localized: "diagnostics.refresh.security \(format(report.securities))"))
        if !report.reasons.isEmpty {
            lines.append(String(localized: "diagnostics.refresh.reasons \(format(report.reasons))"))
        }
        if !report.changedParameters.isEmpty {
            lines.append(String(localized: "diagnostics.refresh.parameters \(format(report.changedParameters))"))
        }
        if report.nondeterministicCount > 0 {
            lines.append(String(localized: "diagnostics.refresh.nondeterministic \(report.nondeterministicCount)"))
        }
        for change in report.statusChanges {
            let parameters = change.changedParameters.isEmpty ? "—" : change.changedParameters.joined(separator: ", ")
            lines.append(String(localized: "diagnostics.refresh.statusChange \(change.name) \(status(change.from)) \(status(change.to)) \(parameters)"))
        }
        return lines
    }

    /// Статус для показа: «поддерживается» или код причины.
    private static func status(_ code: String) -> String {
        code == SubscriptionDiagnostics.supportedStatus ? String(localized: "diagnostics.refresh.supported") : code
    }
}
