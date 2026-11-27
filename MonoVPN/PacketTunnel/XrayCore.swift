#if MONO_CORE_XRAY
import Foundation
import LibXray

/// Обёртка над C API LibXray (`CGoInvoke` / `CGoFree`, libXray v26.11.9, apiVersion 3).
///
/// Запрос — JSON `{"apiVersion":3,"method":...,"payload":{...}}`, ответ —
/// `{"success":bool,"data":...,"error":"..."}` (`invoke.go`). В процессе одновременно работает
/// один экземпляр Xray (`xray.RunXray` возвращает `ErrAlreadyRunning`). На iOS libXray при запуске
/// ставит `GOGC=10`, мягкий лимит памяти Go 30 МБ и раз в секунду возвращает память системе
/// (`memory/memory_ios.go`).
enum XrayCore {
    /// Версия API `Invoke`, которую принимает libXray v26.11.9.
    static let apiVersion = 3

    /// Ошибка ядра: текст уже очищен от секретов.
    struct Failure: LocalizedError {
        /// Очищенный текст ошибки.
        let message: String
        /// Текст для интерфейса.
        var errorDescription: String? { message }
    }

    /// Запускает Xray с конфигурацией JSON.
    static func run(configuration: String) throws {
        _ = try invoke("runXray", payload: ["xrayJson": configuration])
    }

    /// Останавливает Xray; повторный вызов безопасен.
    static func stop() throws {
        _ = try invoke("stopXray", payload: nil)
    }

    /// Версия Xray-core, например `26.11.9`.
    static func version() -> String? {
        (try? invoke("xrayVersion", payload: nil))?["version"] as? String
    }

    /// Работает ли экземпляр Xray.
    static func isRunning() -> Bool {
        ((try? invoke("getXrayState", payload: nil))?["running"] as? Bool) ?? false
    }

    /// Вызывает метод libXray и возвращает поле `data` ответа.
    private static func invoke(_ method: String, payload: [String: Any]?) throws -> [String: Any]? {
        var request: [String: Any] = ["apiVersion": apiVersion, "method": method]
        if let payload {
            request["payload"] = payload
        }
        let requestData = try JSONSerialization.data(withJSONObject: request, options: [.withoutEscapingSlashes])
        guard let requestJSON = String(data: requestData, encoding: .utf8) else {
            throw Failure(message: "libXray request encoding failed")
        }

        let responseJSON: String = requestJSON.withCString { pointer in
            guard let response = CGoInvoke(UnsafeMutablePointer(mutating: pointer)) else { return "" }
            defer { CGoFree(response) }
            return String(cString: response)
        }

        guard let data = responseJSON.data(using: .utf8),
              let response = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure(message: "libXray returned an invalid response to \(method)")
        }
        guard response["success"] as? Bool == true else {
            let error = response["error"] as? String ?? "unknown error"
            throw Failure(message: TunnelErrorSanitizer.sanitize("\(method): \(error)"))
        }
        return response["data"] as? [String: Any]
    }
}
#endif
