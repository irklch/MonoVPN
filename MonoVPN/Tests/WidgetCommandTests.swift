import Foundation
@testable import MonoVPN
import NetworkExtension
import Testing

/// Тесты команд виджета: идемпотентность и разбор URL.
struct TunnelCommandTests {
    /// «connect» запускает туннель только из остановленных состояний и только при выбранном сервере.
    @Test func connectStartsOnlyFromStoppedStates() {
        #expect(TunnelCommand.connect.action(status: .disconnected, hasConfiguration: true) == .start)
        #expect(TunnelCommand.connect.action(status: .invalid, hasConfiguration: true) == .start)
        // Уже работает / поднимается / ещё останавливается: повторное нажатие ничего не делает.
        for status: NEVPNStatus in [.connecting, .connected, .reasserting, .disconnecting] {
            #expect(TunnelCommand.connect.action(status: status, hasConfiguration: true) == .none)
        }
        // Нет выбранного сервера: никогда не подключаемся.
        #expect(TunnelCommand.connect.action(status: .disconnected, hasConfiguration: false) == .none)
    }

    /// «disconnect» останавливает только активный туннель, даже если сервер уже удалён.
    @Test func disconnectStopsOnlyActiveTunnel() {
        for status: NEVPNStatus in [.connecting, .connected, .reasserting] {
            #expect(TunnelCommand.disconnect.action(status: status, hasConfiguration: true) == .stop)
        }
        for status: NEVPNStatus in [.disconnected, .disconnecting, .invalid] {
            #expect(TunnelCommand.disconnect.action(status: status, hasConfiguration: true) == .none)
        }
        // Туннель, запущенный из приложения, можно остановить, даже если сервер с тех пор удалили.
        #expect(TunnelCommand.disconnect.action(status: .connected, hasConfiguration: false) == .stop)
    }

    /// URL команды разбирается обратно; неизвестные команды и чужие схемы отклоняются.
    @Test func urlRoundTrip() throws {
        #expect(TunnelCommand(url: TunnelCommand.connect.url) == .connect)
        #expect(TunnelCommand(url: try #require(URL(string: "monovpn://disconnect"))) == .disconnect)
        #expect(TunnelCommand(url: try #require(URL(string: "monovpn://toggle"))) == nil)
        #expect(TunnelCommand(url: try #require(URL(string: "https://connect"))) == nil)
    }
}

/// Тесты вычисления состояния виджета.
struct WidgetVPNStateTests {
    /// Состояние виджета выводится из системного статуса, наличия конфигурации и последней ошибки.
    @Test func resolvesFromSystemStatus() {
        #expect(WidgetVPNState.resolve(status: .connected, hasConfiguration: true, lastError: nil) == .connected)
        #expect(WidgetVPNState.resolve(status: .reasserting, hasConfiguration: true, lastError: nil) == .connecting)
        #expect(WidgetVPNState.resolve(status: .disconnecting, hasConfiguration: true, lastError: nil) == .disconnecting)
        #expect(WidgetVPNState.resolve(status: .disconnected, hasConfiguration: true, lastError: nil) == .disconnected)
        #expect(WidgetVPNState.resolve(status: .disconnected, hasConfiguration: true, lastError: "x") == .failed)
        // Конфигурация ещё не установлена → её должно создать приложение.
        #expect(WidgetVPNState.resolve(status: nil, hasConfiguration: true, lastError: nil) == .needsSetup)
        // Нет выбранного сервера.
        #expect(WidgetVPNState.resolve(status: .disconnected, hasConfiguration: false, lastError: nil) == .noServer)
        // Работающий туннель показывается всегда, чтобы его можно было остановить из виджета.
        #expect(WidgetVPNState.resolve(status: .connected, hasConfiguration: false, lastError: nil) == .connected)
    }

    /// Какая команда отправляется нажатием в каждом состоянии.
    @Test func commandsPerState() {
        #expect(WidgetVPNState.connected.command == .disconnect)
        #expect(WidgetVPNState.connecting.command == .disconnect)
        #expect(WidgetVPNState.disconnected.command == .connect)
        #expect(WidgetVPNState.failed.command == .connect)
        #expect(WidgetVPNState.noServer.command == nil)
        #expect(WidgetVPNState.disconnecting.command == nil)
    }
}

/// Тесты сохранения выбранного сервера.
struct SelectedServerTests {
    /// Создаёт подписку из списка ссылок для тестов.
    private func subscription(_ links: [String]) throws -> Subscription {
        Subscription(
            source: .link(links[0]),
            servers: try links.map(ProxyLinkParser.parse),
            issues: [],
            lastUpdated: .now
        )
    }

    /// Выбор сервера переживает обновление подписки; если сервер пропал — выбирается первый.
    @Test func keepsSelectionAcrossRefresh() throws {
        var state = AppState()
        state.replaceSubscription(with: try subscription([Fixture.vlessReality, Fixture.trojan]))
        #expect(state.selectedServer?.proxyProtocol == .vless)

        let trojanID = ProxyLinkParser.stableID(for: Fixture.trojan)
        state.selectedServerID = trojanID
        state.replaceSubscription(with: try subscription([Fixture.shadowsocks, Fixture.trojan]))
        #expect(state.selectedServerID == trojanID)

        // Выбранный сервер исчез: явно переключаемся на первый.
        state.replaceSubscription(with: try subscription([Fixture.shadowsocks]))
        #expect(state.selectedServer?.proxyProtocol == .shadowsocks)
        #expect(state.selectedServerID == state.selectedServer?.id)
    }

    /// Выбор сервера сохраняется после кодирования и декодирования `AppState`.
    @Test func persistsThroughCoding() throws {
        var state = AppState()
        state.replaceSubscription(with: try subscription([Fixture.vlessReality, Fixture.trojan]))
        state.selectedServerID = ProxyLinkParser.stableID(for: Fixture.trojan)
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(decoded.selectedServer?.proxyProtocol == .trojan)
    }
}
