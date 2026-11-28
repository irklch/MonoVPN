import Foundation

/// Ограничения, которые накладываются на любую конфигурацию Xray перед запуском: и на конфиг
/// из JSON-подписки провайдера, и на конфиг, собранный приложением из ссылки.
///
/// Применяется дважды: приложением при импорте подписки (`XrayPanelConfiguration.adapt`)
/// и расширением непосредственно перед запуском ядра (`XrayRuntimeConfiguration.prepare`) —
/// второй раз нужен для конфигураций, сохранённых прежними версиями приложения. Xray получает
/// не исходный текст провайдера, а JSON, заново сериализованный после этих проверок, поэтому
/// повторы ключей в исходном тексте до ядра не доходят.
///
/// Сверено с `infra/conf` Xray-core v26.11.9 и с разбором JSON в Go 1.27 (`encoding/json`):
/// имена полей сопоставляются без учёта регистра ASCII, а `ſ` (U+017F) и `K` (U+212A)
/// совпадают с `s` и `k` — см. `goFoldedName`. Все проверки ниже сравнивают имена так же,
/// поэтому обойти их другим написанием ключа нельзя.
enum XrayConfigurationPolicy {
    /// Конфигурацию нельзя запускать.
    enum Failure: LocalizedError, Equatable {
        /// В конфигурации есть Lua-скрипт: `routing.script`, `dns.script` или `script`
        /// маски `noise` (finalmask). Скрипт заменяет правила маршрутизации, выбор DNS-сервера
        /// или маскировку пакетов целиком, поэтому удалить его, не изменив смысла конфигурации,
        /// нельзя — такая конфигурация отклоняется.
        case luaScript
        /// Поле верхнего уровня (`inbounds`, `routing`, `dns`, ...) задано несколько раз
        /// в разном написании. Xray применил бы их в порядке следования в тексте, а его после
        /// разбора JSON не восстановить, — неизвестно, какая конфигурация была бы запущена.
        case ambiguousKeys

        var errorDescription: String? {
            switch self {
            case .luaScript: String(localized: "tunnel.error.luaScript", table: "Tunnel")
            case .ambiguousKeys: String(localized: "tunnel.error.ambiguousKeys", table: "Tunnel")
            }
        }
    }

    /// Журнал Xray полностью выключен: нет журнала доступа (посещённые адреса), журнала
    /// ошибок, журнала DNS-запросов. `loglevel: none` в Xray дополнительно отключает оба журнала.
    /// Вычисляемое свойство: `[String: Any]` не `Sendable` и не может быть статической константой.
    static var disabledLog: [String: Any] {
        [
            "access": "none",
            "error": "none",
            "loglevel": "none",
            "dnsLog": false,
        ]
    }

    /// Поля верхнего уровня конфигурации Xray (`infra/conf/xray.go`, `type Config`).
    /// Ключ, который Xray сопоставил бы с одним из них, приводится к этому написанию.
    static let rootFields = [
        "transport", "env", "log", "routing", "dns", "inbounds", "outbounds", "policy", "api",
        "metrics", "stats", "reverse", "fakeDns", "observatory", "burstObservatory", "version", "geodata",
    ]

    /// Переменные окружения Xray (`env`), которые разрешено задавать конфигурации: только
    /// настройки буферов и протоколов (`common/platform/platform.go`). Не допускаются, в
    /// частности, `xray.xudp.show` (вывод отладочных сведений XUDP), `xray.location.*`
    /// (каталоги, из которых Xray читает файлы, в том числе Lua-скрипты), `xray.browser.dialer`,
    /// `xray.tun.fd` (его задаёт только расширение) и любые другие переменные процесса.
    static let allowedEnvironmentFlags = [
        "xray.buf.readv",
        "xray.buf.splice",
        "xray.vmess.padding",
        "xray.cone.disabled",
        "xray.json.strict",
        "xray.ray.buffer.size",
        "xray.xudp.basekey",
    ]

    /// Имена переменных, которые Xray действительно читает для разрешённых флагов: само имя
    /// и его форма `XRAY_BUF_READV` (`platform.NewEnvFlag`: `Name` и `AltName`). Имена
    /// чувствительны к регистру; любое другое написание Xray не прочитает, и оно убирается.
    static let allowedEnvironmentKeys: Set<String> = Set(
        allowedEnvironmentFlags.flatMap { [$0, environmentAltName($0)] }
    )

    /// Результат применения политики.
    struct Sanitized {
        /// Конфигурация с выключенным журналом и без запрещённых параметров.
        var root: [String: Any]
        /// Имена убранных параметров, без значений (для диагностики импорта), по алфавиту.
        var droppedParameters: [String]
    }

    /// Проверяет конфигурацию и убирает из неё всё, что включает журналы или отладочный вывод.
    ///
    /// - Бросает `Failure.luaScript`, если в конфигурации есть поле `script` со значением.
    /// - Бросает `Failure.ambiguousKeys`, если поле верхнего уровня задано несколько раз
    ///   в разном написании (кроме `log`, который заменяется, и `env` без противоречий).
    /// - Приводит поля верхнего уровня к написанию из `rootFields`.
    /// - Заменяет `log` на `disabledLog`.
    /// - Убирает `masterKeyLog` (запись ключей TLS-сессий в файл), если он включён.
    /// - Убирает `debug: true` из параметров QUIC (`quicParams`, `quicConfig`): он включает
    ///   отладочный вывод алгоритмов управления перегрузкой Hysteria.
    /// - Оставляет в `env` только `allowedEnvironmentKeys`.
    ///
    /// Остальные параметры не меняются; не меняются и безвредные значения этих полей
    /// (`debug: false`, пустой или `"none"` `masterKeyLog`, пустой `script`).
    static func sanitize(_ original: [String: Any]) throws -> Sanitized {
        if containsLuaScript(original) {
            throw Failure.luaScript
        }
        var dropped = Set<String>()
        var root = try canonicalizingRootFields(original)
        root = stripping(root, inQUICParameters: false, dropped: &dropped) as? [String: Any] ?? root

        if let environment = root["env"] as? [String: Any] {
            var allowed: [String: Any] = [:]
            for (name, value) in environment {
                if allowedEnvironmentKeys.contains(name) {
                    allowed[name] = value
                } else {
                    dropped.insert("env.\(name)")
                }
            }
            if allowed.isEmpty {
                root.removeValue(forKey: "env")
            } else {
                root["env"] = allowed
            }
        }

        root["log"] = disabledLog
        return Sanitized(root: root, droppedParameters: dropped.sorted())
    }

    /// Есть ли где-либо в конфигурации поле `script` (в любом написании, которое Xray
    /// сопоставил бы с ним) со значением, отличным от `null` и пустой строки.
    ///
    /// Поиск идёт по всему дереву, а не только по известным путям (`routing.script`,
    /// `dns.script`, `streamSettings.finalmask…noise.settings.script`): других полей с таким
    /// именем в Xray-core v26.11.9 нет, а новые места, где допускается скрипт, тоже будут
    /// отклонены. Значение другого типа (число, объект) тоже считается скриптом.
    static func containsLuaScript(_ value: Any) -> Bool {
        if let object = value as? [String: Any] {
            for (key, child) in object {
                if matches(key, "script"), !isUnset(child) {
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

    /// Имя поля в виде, в котором его сравнивает Go `encoding/json`: ASCII без учёта
    /// регистра, `ſ` (U+017F) — как `s`, `K` (U+212A, знак Кельвина) — как `k`. Других
    /// символов, которые Go считал бы равными латинским буквам, нет (`unicode.SimpleFold`).
    static func goFoldedName(_ name: String) -> String {
        var result = String.UnicodeScalarView()
        for scalar in name.unicodeScalars {
            switch scalar.value {
            case 0x41...0x5A: result.append(Unicode.Scalar(scalar.value + 0x20) ?? scalar)
            case 0x017F: result.append("s")
            case 0x212A: result.append("k")
            default: result.append(scalar)
            }
        }
        return String(result)
    }

    /// Сопоставил бы Go ключ JSON `key` с полем `field`.
    static func matches(_ key: String, _ field: String) -> Bool {
        goFoldedName(key) == goFoldedName(field)
    }

    /// Вторая форма имени переменной, которую читает Xray: `xray.buf.readv` → `XRAY_BUF_READV`
    /// (`platform.NormalizeEnvName`).
    static func environmentAltName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).uppercased().replacingOccurrences(of: ".", with: "_")
    }

    // MARK: - Внутреннее

    /// Приводит поля верхнего уровня к написанию из `rootFields`.
    ///
    /// Несколько ключей одного поля: все варианты `log` убираются (журнал всё равно
    /// заменяется), объекты `env` объединяются, как это сделал бы Go, если в них нет одной
    /// переменной с разными значениями; в остальных случаях — `Failure.ambiguousKeys`.
    /// Неизвестные Xray ключи не меняются: он их не читает.
    private static func canonicalizingRootFields(_ original: [String: Any]) throws -> [String: Any] {
        var root = original
        for field in rootFields {
            let keys = root.keys.filter { matches($0, field) }
            guard !keys.isEmpty else { continue }
            if field == "log" {
                keys.forEach { root.removeValue(forKey: $0) }
                continue
            }
            if keys.count == 1, let key = keys.first {
                if key != field, let value = root.removeValue(forKey: key) {
                    root[field] = value
                }
                continue
            }
            guard field == "env" else { throw Failure.ambiguousKeys }
            var merged: [String: Any] = [:]
            for key in keys {
                guard let environment = root.removeValue(forKey: key) as? [String: Any] else {
                    throw Failure.ambiguousKeys
                }
                for (name, value) in environment {
                    if let existing = merged[name], !isEqual(existing, value) {
                        throw Failure.ambiguousKeys
                    }
                    merged[name] = value
                }
            }
            root[field] = merged
        }
        return root
    }

    /// Рекурсивно убирает включённый `masterKeyLog` и `debug: true` в параметрах QUIC.
    ///
    /// `inQUICParameters` — значение получено по ключу `quicParams`/`quicConfig`. Массив
    /// передаёт этот признак своим элементам, вложенные объекты — нет: `debug` есть только
    /// у самого объекта параметров QUIC (`QuicParamsConfig`).
    private static func stripping(_ value: Any, inQUICParameters: Bool, dropped: inout Set<String>) -> Any {
        if var object = value as? [String: Any] {
            for key in Array(object.keys) {
                guard let child = object[key] else { continue }
                if matches(key, "masterKeyLog") {
                    if isEnabledKeyLog(child) {
                        object.removeValue(forKey: key)
                        dropped.insert("masterKeyLog")
                    }
                    continue
                }
                if inQUICParameters, matches(key, "debug") {
                    if (child as? Bool) == true {
                        object.removeValue(forKey: key)
                        dropped.insert("quicParams.debug")
                    }
                    continue
                }
                let isQUIC = matches(key, "quicParams") || matches(key, "quicConfig")
                object[key] = stripping(child, inQUICParameters: isQUIC, dropped: &dropped)
            }
            return object
        }
        if let array = value as? [Any] {
            return array.map { stripping($0, inQUICParameters: inQUICParameters, dropped: &dropped) }
        }
        return value
    }

    /// Включён ли журнал ключей TLS: Xray открывает файл, если значение не пустое и не `none`
    /// (`transport/internet/tls/config.go`, `reality/config.go`). Значение другого типа Xray
    /// не примет и конфигурацию не запустит.
    private static func isEnabledKeyLog(_ value: Any) -> Bool {
        guard let path = value as? String else { return false }
        return !path.isEmpty && path != "none"
    }

    /// Поле не задано: `null` или пустая строка (Xray не использует такой скрипт).
    private static func isUnset(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let string = value as? String { return string.isEmpty }
        return false
    }

    /// Равны ли два значения из JSON.
    private static func isEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        (lhs as AnyObject).isEqual(rhs as AnyObject)
    }
}
