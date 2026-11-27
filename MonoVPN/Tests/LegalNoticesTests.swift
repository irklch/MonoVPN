import Foundation
@testable import MonoVPN
import Testing

/// Уведомления о сторонних компонентах входят в приложение и выполняют обязательства лицензий.
struct LegalNoticesTests {
    /// Ресурс читается из бандла приложения; у каждого компонента есть лицензия и ссылки на исходники.
    @Test func noticesAreBundled() throws {
        let notices = try #require(ThirdPartyNotices.load())
        #expect(notices.libXray == "v26.11.9")
        #expect(!notices.components.isEmpty)
        for component in notices.components {
            #expect(!component.texts.isEmpty, "\(component.name)")
            #expect(component.source.hasPrefix("https://"), "\(component.name)")
            #expect(component.sourceArchive.hasPrefix("https://"), "\(component.name)")
            #expect(component.license != "see text", "\(component.name)")
        }
    }

    /// MPL-2.0 (Xray-core): ссылка на исходный код использованной версии.
    @Test func xrayCoreSourceIsLinked() throws {
        let notices = try #require(ThirdPartyNotices.load())
        let xray = try #require(notices.components.first)
        #expect(xray.name == "github.com/xtls/xray-core")
        #expect(xray.license.hasPrefix("MPL-2.0"))
        #expect(xray.source == "https://github.com/XTLS/Xray-core/tree/v26.11.9")
        #expect(xray.texts.contains { $0.text.contains("Mozilla Public License Version 2.0") })
    }

    /// LGPL-3.0: вместе с текстом LGPL приложен текст GNU GPL v3.
    @Test func lgplComponentIncludesGPLText() throws {
        let notices = try #require(ThirdPartyNotices.load())
        let lgpl = notices.components.filter { $0.license.hasPrefix("LGPL") }
        #expect(!lgpl.isEmpty)
        for component in lgpl {
            #expect(component.texts.contains { $0.text.contains("GNU GENERAL PUBLIC LICENSE") && $0.text.contains("Version 3, 29 June 2007") })
        }
    }

    @Test func privacyPolicyURL() {
        #expect(LegalLinks.privacyPolicy.scheme == "https")
        #expect(LegalLinks.privacyPolicy.path.hasSuffix("/privacy/"))
    }
}
