import CryptoKit
import Foundation
import os

// Диагностика последовательных обновлений подписки.
//
// Задача — ответить на вопрос «меняется ли ответ провайдера или проблема внутри приложения»,
// ничего не раскрывая. Поэтому:
// - ответ подписки описывается только хешем SHA-256 и размером;
// - значения параметров ссылок (SNI, authority, path, ключи, UUID, пароли, адреса)
//   никогда не сохраняются как есть — только их хеши, и только внутри снимка, который лежит
//   в Keychain рядом с самими серверами (то есть не раскрывает ничего сверх уже сохранённого);
// - в отчёт, интерфейс и системный журнал попадают только счётчики, имена протоколов/транспортов,
//   коды причин несовместимости, имена изменившихся параметров и имена серверов
//   (имена в журнале помечены как private).

/// Одна запись подписки в снимке: идентичность, классификация и хеши параметров.
struct SubscriptionEntrySnapshot: Codable, Hashable, Sendable {
    /// Группа, внутри которой запись сопоставляется между обновлениями: `схема|имя`.
    /// Не зависит от SNI, authority и прочих параметров, поэтому изменение параметра
    /// видно как «изменение», а не как «удалён + добавлен». Несколько записей с одним
    /// именем сопоставляются сначала по совпадению всех параметров, затем по порядку.
    var group: String
    /// Имя сервера из ссылки (фрагмент или `ps`); `—`, если имени нет.
    var name: String
    /// Схема ссылки: `vless`, `vmess`, `trojan`, `ss` или другая (обрезанная).
    var scheme: String
    /// Транспорт, как его задаёт ссылка (`tcp`, `ws`, `grpc`, `xhttp`, ...; `tcp/http` для headerType=http).
    var transport: String
    /// Режим безопасности из ссылки (`none`, `tls`, `reality`, ...).
    var security: String
    /// `supported`, код ограничения ядра (`transport:xhttp`) или `invalid:<код>` / `scheme:<схема>`.
    var status: String
    /// Имя параметра → короткий хеш значения. Сами значения не хранятся.
    var facets: [String: String]

    /// Поддерживается ли запись подключённым ядром.
    var isSupported: Bool { status == SubscriptionDiagnostics.supportedStatus }
    /// Ссылка корректна, но использует возможность, которой нет в ядре.
    var isUnsupported: Bool { !isSupported && !isInvalid }
    /// Ссылка испорчена или схема неизвестна.
    var isInvalid: Bool { status.hasPrefix("invalid:") || status.hasPrefix("scheme:") }
}

/// Снимок одного ответа подписки. Хранится в `Subscription.snapshot` (Keychain).
struct SubscriptionSnapshot: Codable, Hashable, Sendable {
    /// Когда получен ответ.
    var createdAt: Date
    /// Первые 16 байт SHA-256 от тела ответа как есть (hex).
    var responseHash: String
    /// Хеш отсортированного набора записей: совпадает, если поменялся только порядок строк или пробелы.
    var normalizedHash: String
    /// Размер тела ответа в байтах.
    var byteCount: Int
    /// Записи в порядке появления, без точных дубликатов.
    var entries: [SubscriptionEntrySnapshot]
    /// Точные дубликаты ссылок, отброшенные так же, как их отбрасывает парсер.
    var duplicateCount: Int
    /// Сколько ссылок при повторном разборе дали другой результат. Всегда должно быть 0:
    /// иное означает недетерминированность парсера на устройстве.
    var nondeterministicCount: Int
}

/// Результат сравнения ответа подписки с предыдущим ответом того же источника.
struct SubscriptionRefreshReport: Codable, Hashable, Sendable, Identifiable {
    /// Как изменился ответ провайдера относительно предыдущего.
    enum ResponseChange: String, Codable, Sendable {
        /// Предыдущего ответа нет (первый импорт или другой источник).
        case first
        /// Байт в байт тот же ответ.
        case identical
        /// Те же записи, другой порядок строк или пробелы.
        case reordered
        /// Содержимое ответа изменилось.
        case changed
    }

    /// Смена статуса совместимости одного сервера.
    struct StatusChange: Codable, Hashable, Sendable {
        /// Имя сервера из ссылки.
        var name: String
        /// Статус в предыдущем ответе.
        var from: String
        /// Статус в текущем ответе.
        var to: String
        /// Имена параметров ссылки, значения которых изменились (без значений).
        var changedParameters: [String]
    }

    /// Уникальный ID отчёта.
    var id = UUID()
    /// Когда получен ответ.
    var date: Date
    /// Хеш текущего ответа.
    var responseHash: String
    /// Хеш предыдущего ответа, если он был.
    var previousResponseHash: String?
    /// Как изменился ответ.
    var responseChange: ResponseChange
    /// Размер ответа в байтах.
    var byteCount: Int
    /// Всего записей (без точных дубликатов).
    var total: Int
    /// Поддерживаются ядром.
    var supported: Int
    /// Распознаны, но не поддерживаются ядром.
    var unsupported: Int
    /// Испорчены или с неизвестной схемой.
    var invalid: Int
    /// Точные дубликаты.
    var duplicates: Int
    /// Сколько имён серверов встречается больше одного раза. Такие серверы в списке неотличимы
    /// по имени, и при перестановке строк провайдером может казаться, что «сервер» сменил статус.
    var duplicateNames: Int
    /// Распределение по схемам.
    var protocols: [String: Int]
    /// Распределение по транспортам.
    var transports: [String: Int]
    /// Распределение по режимам безопасности.
    var securities: [String: Int]
    /// Распределение по причинам несовместимости и ошибкам.
    var reasons: [String: Int]
    /// Записи, которых не было в предыдущем ответе.
    var added: Int
    /// Записи предыдущего ответа, которых нет в текущем.
    var removed: Int
    /// Записи, у которых изменился хотя бы один параметр или статус.
    var changed: Int
    /// Имя параметра → у скольких записей изменилось его значение.
    var changedParameters: [String: Int]
    /// Смены статуса совместимости.
    var statusChanges: [StatusChange]
    /// Недетерминированный разбор (должно быть 0).
    var nondeterministicCount: Int

    /// Ответ не изменился, а статусы изменились: это была бы ошибка внутри приложения.
    var indicatesAppBug: Bool {
        nondeterministicCount > 0 || (responseChange != .changed && responseChange != .first && !statusChanges.isEmpty)
    }
}

/// Построение снимков, сравнение и запись в журнал.
enum SubscriptionDiagnostics {
    /// Статус поддерживаемой записи.
    static let supportedStatus = "supported"
    /// Сколько последних отчётов хранится.
    static let maxReports = 10
    /// Системный журнал; значения, которые могут идентифицировать пользователя, — private.
    private static let logger = Logger(subsystem: AppIdentifiers.logSubsystem, category: "SubscriptionDiagnostics")

    // MARK: - Снимок

    /// Строит снимок тела ответа подписки. Никогда не бросает: диагностика не должна ломать импорт.
    static func snapshot(of data: Data, at date: Date = .now) -> SubscriptionSnapshot {
        let lines = SubscriptionParser.text(from: data).flatMap { try? SubscriptionParser.entries(in: $0) } ?? []
        return snapshot(lines: lines, responseHash: hash(data), byteCount: data.count, at: date)
    }

    /// Снимок одиночной ссылки (источник `.link`).
    static func snapshot(ofLink link: String, at date: Date = .now) -> SubscriptionSnapshot {
        let data = Data(link.utf8)
        return snapshot(lines: [link.trimmingCharacters(in: .whitespacesAndNewlines)], responseHash: hash(data), byteCount: data.count, at: date)
    }

    /// Общая часть: классифицирует каждую строку так же, как `SubscriptionParser`.
    private static func snapshot(lines: [String], responseHash: String, byteCount: Int, at date: Date) -> SubscriptionSnapshot {
        var entries: [SubscriptionEntrySnapshot] = []
        var seenLinks = Set<String>()
        var duplicates = 0
        var nondeterministic = 0

        for line in lines where line.contains("://") {
            // Точные дубликаты парсер отбрасывает по ID (хешу ссылки) — делаем так же.
            guard seenLinks.insert(ProxyLinkParser.stableID(for: line)).inserted else {
                duplicates += 1
                continue
            }
            let scheme = safeToken(line.components(separatedBy: "://")[0].lowercased())
            let name = ProxyLinkParser.displayName(of: line) ?? "—"

            let status: String
            if ProxyLinkParser.isProxyLink(line) {
                let first = Result { try ProxyLinkParser.parse(line) }
                let second = Result { try ProxyLinkParser.parse(line) }
                if !same(first, second) { nondeterministic += 1 }
                switch first {
                case let .success(server):
                    status = server.incompatibility.map(\.diagnosticCode) ?? supportedStatus
                case let .failure(error):
                    status = "invalid:" + ((error as? ProxyLinkError)?.diagnosticCode ?? "unknown")
                }
            } else {
                status = "scheme:" + scheme
            }

            let raw = rawParameters(of: line, scheme: scheme)
            entries.append(SubscriptionEntrySnapshot(
                group: "\(scheme)|\(name)",
                name: name,
                scheme: scheme,
                transport: raw.transport,
                security: raw.security,
                status: status,
                facets: raw.facets
            ))
        }

        // Порядок и пробелы не важны: хешируем отсортированные ID ссылок.
        let normalized = seenLinks.sorted().joined(separator: "\n")
        return SubscriptionSnapshot(
            createdAt: date,
            responseHash: responseHash,
            normalizedHash: hash(Data(normalized.utf8)),
            byteCount: byteCount,
            entries: entries,
            duplicateCount: duplicates,
            nondeterministicCount: nondeterministic
        )
    }

    /// Совпадают ли два результата разбора одной ссылки.
    private static func same(_ lhs: Result<ServerConfiguration, any Error>, _ rhs: Result<ServerConfiguration, any Error>) -> Bool {
        switch (lhs, rhs) {
        case let (.success(a), .success(b)): a == b
        case let (.failure(a), .failure(b)): (a as? ProxyLinkError) == (b as? ProxyLinkError)
        default: false
        }
    }

    // MARK: - Сравнение

    /// Сравнивает текущий снимок с предыдущим снимком того же источника (`nil` — первый ответ).
    static func report(previous: SubscriptionSnapshot?, current: SubscriptionSnapshot) -> SubscriptionRefreshReport {
        let entries = current.entries
        var report = SubscriptionRefreshReport(
            date: current.createdAt,
            responseHash: current.responseHash,
            previousResponseHash: previous?.responseHash,
            responseChange: .first,
            byteCount: current.byteCount,
            total: entries.count,
            supported: entries.filter(\.isSupported).count,
            unsupported: entries.filter(\.isUnsupported).count,
            invalid: entries.filter(\.isInvalid).count,
            duplicates: current.duplicateCount,
            duplicateNames: Dictionary(grouping: entries, by: \.group).values.filter { $0.count > 1 }.count,
            protocols: histogram(entries.map(\.scheme)),
            transports: histogram(entries.map(\.transport)),
            securities: histogram(entries.map(\.security)),
            reasons: histogram(entries.filter { !$0.isSupported }.map(\.status)),
            added: 0,
            removed: 0,
            changed: 0,
            changedParameters: [:],
            statusChanges: [],
            nondeterministicCount: current.nondeterministicCount
        )
        guard let previous else { return report }

        if previous.responseHash == current.responseHash {
            report.responseChange = .identical
        } else if previous.normalizedHash == current.normalizedHash {
            report.responseChange = .reordered
        } else {
            report.responseChange = .changed
        }

        // Сопоставление: внутри группы сначала полностью совпадающие записи (так перестановка
        // одноимённых серверов не выглядит сменой статуса), затем оставшиеся по порядку.
        var pool = Dictionary(grouping: previous.entries, by: \.group)
        var matches = [SubscriptionEntrySnapshot?](repeating: nil, count: entries.count)
        for (index, entry) in entries.enumerated() {
            if let candidates = pool[entry.group],
               let found = candidates.firstIndex(where: { $0.facets == entry.facets && $0.status == entry.status }) {
                matches[index] = pool[entry.group]?.remove(at: found)
            }
        }
        for (index, entry) in entries.enumerated() where matches[index] == nil {
            if let candidates = pool[entry.group], !candidates.isEmpty {
                matches[index] = pool[entry.group]?.removeFirst()
            }
        }
        report.removed = pool.values.reduce(0) { $0 + $1.count }

        var parameterCounts: [String: Int] = [:]
        for (index, entry) in entries.enumerated() {
            guard let before = matches[index] else {
                report.added += 1
                continue
            }
            let changedKeys = Set(before.facets.keys).union(entry.facets.keys)
                .filter { before.facets[$0] != entry.facets[$0] }
                .sorted()
            if !changedKeys.isEmpty || before.status != entry.status {
                report.changed += 1
            }
            for key in changedKeys {
                parameterCounts[key, default: 0] += 1
            }
            if before.status != entry.status {
                report.statusChanges.append(.init(name: entry.name, from: before.status, to: entry.status, changedParameters: changedKeys))
            }
        }
        report.changedParameters = parameterCounts
        return report
    }

    /// Добавляет отчёт в историю, оставляя последние `maxReports`.
    static func appending(_ report: SubscriptionRefreshReport, to history: [SubscriptionRefreshReport]?) -> [SubscriptionRefreshReport] {
        Array(((history ?? []) + [report]).suffix(maxReports))
    }

    // MARK: - Журнал

    /// Пишет отчёт в системный журнал (Console.app, категория `SubscriptionDiagnostics`).
    /// Публичны только счётчики, хеш ответа и коды; имена серверов — private.
    static func log(_ report: SubscriptionRefreshReport) {
        logger.notice("""
            Subscription response \(report.responseHash, privacy: .public) \
            (previous \(report.previousResponseHash ?? "none", privacy: .public), \(report.responseChange.rawValue, privacy: .public), \
            \(report.byteCount, privacy: .public) bytes): total \(report.total, privacy: .public), \
            supported \(report.supported, privacy: .public), unsupported \(report.unsupported, privacy: .public), \
            invalid \(report.invalid, privacy: .public), duplicates \(report.duplicates, privacy: .public), \
            duplicate names \(report.duplicateNames, privacy: .public); \
            added \(report.added, privacy: .public), removed \(report.removed, privacy: .public), \
            changed \(report.changed, privacy: .public); nondeterministic \(report.nondeterministicCount, privacy: .public)
            """)
        logger.notice("""
            protocols [\(format(report.protocols), privacy: .public)] \
            transports [\(format(report.transports), privacy: .public)] \
            security [\(format(report.securities), privacy: .public)] \
            reasons [\(format(report.reasons), privacy: .public)] \
            changed parameters [\(format(report.changedParameters), privacy: .public)]
            """)
        for change in report.statusChanges {
            logger.notice("""
                Status change \(change.name, privacy: .private): \(change.from, privacy: .public) -> \(change.to, privacy: .public); \
                changed parameters [\(change.changedParameters.joined(separator: ","), privacy: .public)]
                """)
        }
        if report.indicatesAppBug {
            logger.fault("Subscription compatibility changed without a provider response change")
        }
    }

    /// `ключ=число` через запятую, по убыванию числа, затем по ключу.
    static func format(_ counts: [String: Int]) -> String {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")
    }

    // MARK: - Сырые параметры ссылки

    /// Транспорт, режим безопасности и хеши значений всех параметров ссылки — без самих значений.
    ///
    /// Адрес, порт и учётные данные тоже хешируются (`address`, `port`, `credentials`), чтобы
    /// было видно, что их поменял провайдер; имя сервера не хешируется — это идентичность записи.
    static func rawParameters(of link: String, scheme: String) -> (transport: String, security: String, facets: [String: String]) {
        var values: [String: String] = [:]
        var defaultSecurity = "none"

        if scheme == "vmess" {
            for (key, value) in vmessFields(link) where key != "ps" {
                switch key {
                case "add": values["address"] = value
                case "id": values["credentials"] = value
                default: values[key] = value
                }
            }
            // Поля v2rayN приводим к именам, как в ссылках VLESS. В VMess `type` — это
            // headerType (или режим gRPC), а транспорт задаёт `net`.
            let header = values.removeValue(forKey: "type")
            values["type"] = values.removeValue(forKey: "net") ?? "tcp"
            if let header { values["headerType"] = header }
            if let tls = values.removeValue(forKey: "tls") { values["security"] = tls }
        } else {
            if scheme == "trojan" { defaultSecurity = "tls" }
            var body = link
            if let hash = body.lastIndex(of: "#") { body = String(body[..<hash]) }
            if let components = URLComponents(string: body), let host = components.percentEncodedHost, !host.isEmpty {
                values["address"] = host.lowercased()
                values["port"] = components.port.map(String.init) ?? ""
                values["credentials"] = (components.percentEncodedUser ?? "") + ":" + (components.percentEncodedPassword ?? "")
                for item in components.queryItems ?? [] where values[item.name] == nil {
                    values[item.name] = item.value ?? ""
                }
            } else if let range = body.range(of: "://") {
                // Старый формат ss://base64(...) — хешируем целиком.
                values["payload"] = String(body[range.upperBound...])
            }
        }

        var transport = safeToken((values["type"].flatMap { $0.isEmpty ? nil : $0 } ?? "tcp").lowercased())
        if scheme == "ss" {
            let plugin = values["plugin"].map { $0.components(separatedBy: ";")[0] } ?? ""
            transport = plugin.isEmpty ? "tcp" : "plugin:" + safeToken(plugin.lowercased())
        } else if let header = values["headerType"]?.lowercased(), !header.isEmpty, header != "none",
                  transport == "tcp" || transport == "raw" {
            transport += "/" + safeToken(header)
        }
        let security = safeToken((values["security"].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSecurity).lowercased())

        var facets: [String: String] = [:]
        for (key, value) in values {
            facets[safeToken(key)] = shortHash(key + "=" + value)
        }
        return (transport, security, facets)
    }

    /// Поля JSON ссылки VMess как строки; пустой словарь, если это не JSON.
    private static func vmessFields(_ link: String) -> [String: String] {
        guard let range = link.range(of: "://") else { return [:] }
        var payload = String(link[range.upperBound...])
        if let hash = payload.firstIndex(of: "#") { payload = String(payload[..<hash]) }
        guard let data = Base64.decode(payload),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        var fields: [String: String] = [:]
        for (key, value) in json {
            if let string = value as? String {
                fields[key] = string.trimmingCharacters(in: .whitespaces)
            } else if let number = value as? NSNumber {
                fields[key] = number.stringValue
            }
        }
        return fields
    }

    // MARK: - Вспомогательное

    /// Первые 16 байт SHA-256 в hex.
    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Первые 8 байт SHA-256 в hex — только для сравнения значений внутри снимка.
    private static func shortHash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Гистограмма значений.
    private static func histogram(_ values: [String]) -> [String: Int] {
        values.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    /// Оставляет в строке только `[a-z0-9._+/-]` и не больше 32 символов: имена протоколов
    /// и параметров приходят от провайдера и не должны тащить в журнал произвольный текст.
    static func safeToken(_ value: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+/-")
        let filtered = String(value.filter { allowed.contains($0) }.prefix(32))
        return filtered.isEmpty ? "?" : filtered
    }
}

extension ProxyLinkError {
    /// Безопасный для журнала код причины: имя случая и, где это имя протокола/транспорта,
    /// значение из ссылки. Значения, которые могут быть адресом или секретом (authority), не включаются.
    var diagnosticCode: String {
        let token = SubscriptionDiagnostics.safeToken
        return switch self {
        case let .unsupportedScheme(scheme): "scheme:" + token(scheme)
        case .malformed: "malformed"
        case .missingHost: "missingHost"
        case .invalidPort: "invalidPort"
        case .invalidUUID: "invalidUUID"
        case .missingPassword: "missingPassword"
        case let .unsupportedEncryption(value): "encryption:" + token(value)
        case let .unsupportedSecurity(value): "security:" + token(value)
        case let .unsupportedTransport(value): "transport:" + token(value)
        case let .unsupportedHeaderType(value): "headerType:" + token(value)
        case let .unsupportedFlow(value): "flow:" + token(value)
        case .flowRequiresTLS: "flowRequiresTLS"
        case .invalidRealityPublicKey: "invalidRealityPublicKey"
        case .invalidRealityShortID: "invalidRealityShortID"
        case let .unsupportedShadowsocksMethod(value): "ssMethod:" + token(value)
        case let .unsupportedShadowsocksPlugin(value): "ssPlugin:" + token(value.components(separatedBy: " ")[0])
        case .unsupportedGRPCAuthority: "grpcAuthorityMismatch"
        }
    }
}
