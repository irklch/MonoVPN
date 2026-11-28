import Foundation

/// Разбор JSON-подписки Xray: массив готовых конфигов (каждый — объект с `remarks`,
/// `outbounds`, `routing`, `dns`, ...), как его отдают клиентам вроде Streisand.
enum XrayJSONSubscriptionParser {
    /// Результат разбора: серверы для списка и их конфиги (по `ServerConfiguration.id`).
    struct Result: Equatable {
        var servers: [ServerConfiguration]
        var configurations: [String: String]
        var issues: [ParseIssue]
    }

    /// Похож ли ответ на JSON-подписку Xray (массив объектов с `outbounds`).
    static func looksLikeJSONSubscription(_ data: Data) -> Bool {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any], !array.isEmpty else {
            return false
        }
        return array.contains { ($0 as? [String: Any])?["outbounds"] is [Any] }
    }

    /// Разбирает ответ. Конфиг, который не удалось адаптировать или который запрещён
    /// `XrayConfigurationPolicy` (Lua-скрипт), попадает в `issues`.
    static func parse(_ data: Data) throws -> Result {
        guard let array = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            throw SubscriptionParseError.unsupportedFormat("JSON")
        }
        var servers: [ServerConfiguration] = []
        var configurations: [String: String] = [:]
        var issues: [ParseIssue] = []
        var usedIDs = Set<String>()

        for (index, element) in array.enumerated() {
            guard let root = element as? [String: Any] else { continue }
            let remarks = (root["remarks"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (remarks?.isEmpty ?? true) ? String(localized: "server.unnamed \(index + 1)") : remarks!

            do {
                let adapted = try XrayPanelConfiguration.adapt(root)
                let summary = XrayPanelConfiguration.summary(of: root)
                guard summary.serverCount > 0 else { throw XrayPanelConfiguration.Failure.noOutbounds }

                // ID от имени: не меняется, когда панель обновляет ключи или адреса,
                // поэтому выбор сервера переживает обновление подписки.
                var id = "json-" + ProxyLinkParser.stableID(for: "xray-json|" + name)
                var suffix = 2
                while usedIDs.contains(id) {
                    id = "json-" + ProxyLinkParser.stableID(for: "xray-json|\(name)|\(suffix)")
                    suffix += 1
                }
                usedIDs.insert(id)

                var server = ServerConfiguration(
                    id: id,
                    name: name,
                    proxyProtocol: ProxyProtocol(rawValue: (summary.mainProtocol ?? "").lowercased()) ?? .vless,
                    host: summary.host ?? "",
                    port: summary.port ?? 0
                )
                server.panel = PanelServerInfo(
                    summary: summary.text,
                    serverCount: summary.serverCount,
                    configHash: ProxyLinkParser.stableID(for: adapted.json)
                )
                server.ignoredParameters = adapted.droppedGeoEntries
                servers.append(server)
                configurations[id] = adapted.json
            } catch let failure as XrayConfigurationPolicy.Failure {
                // Lua-скрипт провайдера не исполняется: сервер в списке не появляется,
                // причина видна в «Подписка → Диагностика импорта».
                issues.append(ParseIssue(name: name, reason: failure.localizedDescription))
            } catch {
                issues.append(ParseIssue(name: name, reason: String(localized: "error.subscription.jsonConfig")))
            }
        }

        guard !servers.isEmpty else {
            throw SubscriptionParseError.noSupportedServers(issues)
        }
        return Result(servers: servers, configurations: configurations, issues: issues)
    }
}
