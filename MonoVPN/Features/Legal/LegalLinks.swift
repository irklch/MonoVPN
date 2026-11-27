import Foundation

/// Внешние юридические страницы Mono VPN.
enum LegalLinks {
    /// Политика конфиденциальности (сайт Mono VPN, раздел «Конфиденциальность»).
    /// Тот же адрес указывается в App Store Connect → App Privacy → Privacy Policy URL.
    static let privacyPolicy = URL(string: "https://irklch.github.io/monovpn-site/privacy/")!
}

/// Лицензии и уведомления сторонних компонентов, которые входят в сборку
/// (`Resources/ThirdPartyNotices.json`, генерируется `Scripts/generate-third-party-notices.sh`).
struct ThirdPartyNotices: Decodable, Equatable, Sendable {
    /// Один сторонний компонент.
    struct Component: Decodable, Equatable, Identifiable, Sendable {
        /// Один файл лицензии или уведомления (LICENSE, NOTICE, PATENTS, ...).
        struct Document: Decodable, Equatable, Sendable {
            /// Имя файла в исходниках компонента.
            var title: String
            /// Полный текст без изменений.
            var text: String
        }

        /// Путь модуля Go или название компонента.
        var name: String
        /// Версия, точно соответствующая сборке.
        var version: String
        /// Версия для показа (например, тег вместо псевдоверсии); `nil` — `version`.
        var displayVersion: String?
        /// Лицензия (SPDX).
        var license: String
        /// Репозиторий исходного кода.
        var source: String
        /// Архив исходного кода именно этой версии.
        var sourceArchive: String
        /// Файлы под другой лицензией или с другим правообладателем.
        var notes: [String]
        /// Тексты лицензий и уведомлений.
        var texts: [Document]

        var id: String { name }
    }

    /// Версия libXray, из которой собраны компоненты.
    var libXray: String
    /// Версия Go.
    var go: String
    /// Компоненты: Xray-core и libXray первыми, затем по алфавиту.
    var components: [Component]

    /// Загружает уведомления из бандла приложения; `nil`, если ресурс недоступен.
    static func load(bundle: Bundle = .main) -> ThirdPartyNotices? {
        guard let url = bundle.url(forResource: "ThirdPartyNotices", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ThirdPartyNotices.self, from: data)
    }
}
