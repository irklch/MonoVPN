import Foundation

/// Ограничения, которые накладываются на любую конфигурацию Xray перед запуском: и на конфиг
/// из JSON-подписки провайдера, и на конфиг, собранный приложением из ссылки.
///
/// Применяется дважды: приложением при импорте подписки (`XrayPanelConfiguration.adapt`)
/// и расширением непосредственно перед запуском ядра (`XrayRuntimeConfiguration.prepare`) —
/// второй раз нужен для конфигураций, сохранённых прежними версиями приложения.
///
/// Сверено с `infra/conf` Xray-core v26.11.9. Go (`encoding/json`) сопоставляет имена полей
/// без учёта регистра, поэтому все ключи здесь сравниваются так же.
enum XrayConfigurationPolicy {
    /// Конфигурацию нельзя запускать.
    enum Failure: LocalizedError, Equatable {
        /// В конфигурации есть Lua-скрипт: `routing.script`, `dns.script` или `script`
        /// маски `noise` (finalmask). Скрипт заменяет правила маршрутизации, выбор DNS-сервера
        /// или маскировку пакетов целиком, поэтому удалить его, не изменив смысла конфигурации,
        /// нельзя — такая конфигурация отклоняется.
        case luaScript

        var errorDescription: String? {
            String(localized: "tunnel.error.luaScript", table: "Tunnel")
        }
    }

    /// Журнал Xray полностью выключен: нет журнала доступа (посещённые адреса), журнала
    /// ошибок, журнала DNS-запросов. `loglevel: none` в Xray дополнительно отключает оба журнала.
    static let disabledLog: [String: Any] = [
        "access": "none",
        "error": "none",
        "loglevel": "none",
        "dnsLog": false,
    ]

    /// Переменные окружения Xray (`env`), которые разрешено задавать конфигурации: только
    /// настройки буферов и протоколов. Не допускаются, в частности, `xray.xudp.show` (вывод
    /// отладочных сведений XUDP), `xray.location.*` (каталоги, из которых Xray читает файлы,
    /// в том числе Lua-скрипты), `xray.browser.dialer` и любые другие переменные процесса.
    /// `xray.tun.fd` задаёт только расширение.
    static let allowedEnvironmentKeys: Set<String> = [
        "xray.buf.readv",
        "xray.buf.splice",
        "xray.vmess.padding",
        "xray.cone.disabled",
        "xray.json.strict",
        "xray.ray.buffer.size",
        "xray.xudp.basekey",
        XrayTunnelLayout.tunFdEnvKey,
    ]

    /// Результат применения политики.
    struct Sanitized {
        /// Конфигурация с выключенным журналом и без запрещённых параметров.
        var root: [String: Any]
        /// Имена убранных параметров, без значений (для диагностики импорта), по алфавиту.
        var droppedParameters: [String]
    }

    /// Проверяет конфигурацию и убирает из неё всё, что включает журналы или отладочный вывод.
    ///
    /// - Бросает `Failure.luaScript`, если в конфигурации есть непустое поле `script`.
    /// - Заменяет `log` на `disabledLog` (в том числе варианты имени в другом регистре).
    /// - Убирает `masterKeyLog` (запись ключей TLS-сессий в файл) из любых настроек TLS/REALITY.
    /// - Убирает `debug` из параметров QUIC (`quicParams`, `quicConfig`): он включает
    ///   отладочный вывод алгоритмов управления перегрузкой Hysteria.
    /// - Оставляет в `env` только `allowedEnvironmentKeys`.
    ///
    /// Остальные параметры не меняются.
    static func sanitize(_ original: [String: Any]) throws -> Sanitized {
        if containsLuaScript(original) {
            throw Failure.luaScript
        }
        var dropped = Set<String>()
        var root = stripping(original, dropped: &dropped) as? [String: Any] ?? original

        var environment: [String: Any] = [:]
        for key in root.keys where key.lowercased() == "env" {
            for (name, value) in root[key] as? [String: Any] ?? [:] {
                if allowedEnvironmentKeys.contains(normalizedEnvironmentKey(name)) {
                    environment[name] = value
                } else {
                    dropped.insert("env.\(name)")
                }
            }
            root.removeValue(forKey: key)
        }
        if !environment.isEmpty {
            root["env"] = environment
        }

        for key in root.keys where key.lowercased() == "log" {
            root.removeValue(forKey: key)
        }
        root["log"] = disabledLog

        return Sanitized(root: root, droppedParameters: dropped.sorted())
    }

    /// Есть ли где-либо в конфигурации поле `script` с непустым значением.
    ///
    /// Поиск идёт по всему дереву, а не только по известным путям (`routing.script`,
    /// `dns.script`, `streamSettings.finalmask…noise.settings.script`): других полей с таким
    /// именем в Xray-core v26.11.9 нет, а новые места, где допускается скрипт, тоже будут
    /// отклонены.
    static func containsLuaScript(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if key.lowercased() == "script", !isEmptyValue(child) {
                    return true
                }
                if containsLuaScript(child) {
                    return true
                }
            }
            return false
        }
        if let array = value as? [Any] {
            return array.contains { containsLuaScript($0) }
        }
        return false
    }

    /// Имя переменной окружения в виде, в котором его понимает Xray: `XRAY_XUDP_SHOW` и
    /// `xray.xudp.show` — одна и та же переменная (`platform.NormalizeEnvName`).
    static func normalizedEnvironmentKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "_", with: ".")
    }

    // MARK: - Внутреннее

    /// Рекурсивно убирает `masterKeyLog`, пустые `script` и `debug` в параметрах QUIC.
    private static func stripping(_ value: Any, insideQUIC: Bool = false, dropped: inout Set<String>) -> Any {
        if var object = value as? [String: Any] {
            for key in Array(object.keys) {
                let lower = key.lowercased()
                if lower == "masterkeylog" {
                    object.removeValue(forKey: key)
                    dropped.insert("masterKeyLog")
                    continue
                }
                if lower == "script" {
                    // Непустой скрипт отклоняется раньше; пустое поле Xray и так не использует.
                    object.removeValue(forKey: key)
                    continue
                }
                if insideQUIC, lower == "debug" {
                    object.removeValue(forKey: key)
                    dropped.insert("quicParams.debug")
                    continue
                }
                if let child = object[key] {
                    let quic = lower == "quicparams" || lower == "quicconfig"
                    object[key] = stripping(child, insideQUIC: quic, dropped: &dropped)
                }
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map { stripping($0, dropped: &dropped) }
        }
        return value
    }

    /// Пустое значение: `null`, пустая строка (в том числе из пробелов), пустой массив или объект.
    private static func isEmptyValue(_ value: Any) -> Bool {
        switch value {
        case is NSNull:
            true
        case let string as String:
            string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case let array as [Any]:
            array.isEmpty
        case let object as [String: Any]:
            object.isEmpty
        default:
            false
        }
    }
}
