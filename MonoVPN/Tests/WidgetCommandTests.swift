import Foundation
@testable import MonoVPN
import NetworkExtension
import Testing

struct TunnelCommandTests {
    @Test func connectStartsOnlyFromStoppedStates() {
        #expect(TunnelCommand.connect.action(status: .disconnected, hasConfiguration: true) == .start)
        #expect(TunnelCommand.connect.action(status: .invalid, hasConfiguration: true) == .start)
        // Already running / coming up / still stopping: a repeated tap does nothing.
        for status: NEVPNStatus in [.connecting, .connected, .reasserting, .disconnecting] {
            #expect(TunnelCommand.connect.action(status: status, hasConfiguration: true) == .none)
        }
        // No selected server: never connect.
        #expect(TunnelCommand.connect.action(status: .disconnected, hasConfiguration: false) == .none)
    }

    @Test func disconnectStopsOnlyActiveTunnel() {
        for status: NEVPNStatus in [.connecting, .connected, .reasserting] {
            #expect(TunnelCommand.disconnect.action(status: status, hasConfiguration: true) == .stop)
        }
        for status: NEVPNStatus in [.disconnected, .disconnecting, .invalid] {
            #expect(TunnelCommand.disconnect.action(status: status, hasConfiguration: true) == .none)
        }
        // A tunnel started from the app can be stopped even if the server was removed since.
        #expect(TunnelCommand.disconnect.action(status: .connected, hasConfiguration: false) == .stop)
    }

    @Test func urlRoundTrip() throws {
        #expect(TunnelCommand(url: TunnelCommand.connect.url) == .connect)
        #expect(TunnelCommand(url: try #require(URL(string: "monovpn://disconnect"))) == .disconnect)
        #expect(TunnelCommand(url: try #require(URL(string: "monovpn://toggle"))) == nil)
        #expect(TunnelCommand(url: try #require(URL(string: "https://connect"))) == nil)
    }
}

struct WidgetVPNStateTests {
    @Test func resolvesFromSystemStatus() {
        #expect(WidgetVPNState.resolve(status: .connected, hasConfiguration: true, lastError: nil) == .connected)
        #expect(WidgetVPNState.resolve(status: .reasserting, hasConfiguration: true, lastError: nil) == .connecting)
        #expect(WidgetVPNState.resolve(status: .disconnecting, hasConfiguration: true, lastError: nil) == .disconnecting)
        #expect(WidgetVPNState.resolve(status: .disconnected, hasConfiguration: true, lastError: nil) == .disconnected)
        #expect(WidgetVPNState.resolve(status: .disconnected, hasConfiguration: true, lastError: "x") == .failed)
        // No configuration installed yet → the app must create it.
        #expect(WidgetVPNState.resolve(status: nil, hasConfiguration: true, lastError: nil) == .needsSetup)
        // No selected server.
        #expect(WidgetVPNState.resolve(status: .disconnected, hasConfiguration: false, lastError: nil) == .noServer)
        // A running tunnel is always shown, so it can be stopped from the widget.
        #expect(WidgetVPNState.resolve(status: .connected, hasConfiguration: false, lastError: nil) == .connected)
    }

    @Test func commandsPerState() {
        #expect(WidgetVPNState.connected.command == .disconnect)
        #expect(WidgetVPNState.connecting.command == .disconnect)
        #expect(WidgetVPNState.disconnected.command == .connect)
        #expect(WidgetVPNState.failed.command == .connect)
        #expect(WidgetVPNState.noServer.command == nil)
        #expect(WidgetVPNState.disconnecting.command == nil)
    }
}

struct SelectedServerTests {
    private func subscription(_ links: [String]) throws -> Subscription {
        Subscription(
            source: .link(links[0]),
            servers: try links.map(ProxyLinkParser.parse),
            issues: [],
            lastUpdated: .now
        )
    }

    @Test func keepsSelectionAcrossRefresh() throws {
        var state = AppState()
        state.replaceSubscription(with: try subscription([Fixture.vlessReality, Fixture.trojan]))
        #expect(state.selectedServer?.proxyProtocol == .vless)

        let trojanID = ProxyLinkParser.stableID(for: Fixture.trojan)
        state.selectedServerID = trojanID
        state.replaceSubscription(with: try subscription([Fixture.shadowsocks, Fixture.trojan]))
        #expect(state.selectedServerID == trojanID)

        // The selected server disappeared: fall back to the first one explicitly.
        state.replaceSubscription(with: try subscription([Fixture.shadowsocks]))
        #expect(state.selectedServer?.proxyProtocol == .shadowsocks)
        #expect(state.selectedServerID == state.selectedServer?.id)
    }

    @Test func persistsThroughCoding() throws {
        var state = AppState()
        state.replaceSubscription(with: try subscription([Fixture.vlessReality, Fixture.trojan]))
        state.selectedServerID = ProxyLinkParser.stableID(for: Fixture.trojan)
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        #expect(decoded.selectedServer?.proxyProtocol == .trojan)
    }
}
