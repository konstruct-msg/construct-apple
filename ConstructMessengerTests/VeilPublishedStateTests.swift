import XCTest
import Observation
import Synchronization
import GRPCCore
@testable import Construct_Messenger

@MainActor
final class VeilPublishedStateTests: XCTestCase {
    // Injects FSM transitions and a proxy outcome. A real tunnel and the settings screen on
    // device still need a live check (TODO 188); this stand verifies derivation and observation.
    /// TODO 188: the tunnel is up in the router, but Network settings still says connecting.
    func testAnActiveRouteReachesNetworkSettings() {
        let mirror = TransportRouterMirror.shared
        let previous = mirror.state
        defer { publish(previous) }

        publish(.veilActive(relay: "front.example:443", port: 4242, since: Date(), method: .veilFront))

        XCTAssertTrue(VeilProxyManager.shared.isRunning)
        XCTAssertEqual(VeilProxyManager.shared.activeRelay, "front.example:443")
        XCTAssertEqual(VeilProxyManager.shared.activeMethod, .veilFront)
        XCTAssertEqual(VeilProxyManager.shared.currentTrafficPath, .veilFront(relay: "front.example:443"))
    }

    /// Reading the same getters as NetworkSettingsView must register with SwiftUI observation.
    func testSettingsObserveTheRouteThroughTheManager() {
        let previous = TransportRouterMirror.shared.state
        defer { publish(previous) }
        publish(.direct(consecutiveFails: 0))
        let changed = Mutex(false)
        withObservationTracking {
            _ = VeilProxyManager.shared.currentTrafficPath
        } onChange: {
            changed.withLock { $0 = true }
        }

        publish(.veilProbing)

        XCTAssertTrue(changed.withLock { $0 })
        XCTAssertEqual(VeilProxyManager.shared.currentTrafficPath, .veilConnecting,
                       "Auto also shows probing, rather than falling back to Direct")
    }

    func testLeavingAnActiveRouteClearsRelayAndMethodInSettings() {
        let previous = TransportRouterMirror.shared.state
        defer { publish(previous) }
        let states: [TransportState] = [.veilProbing, .veilCooldown(until: Date()), .offline, .direct(consecutiveFails: 0)]
        for state in states {
            publish(.veilActive(relay: "front.example:443", port: 4242, since: Date(), method: .webTunnel))
            publish(state)

            XCTAssertFalse(VeilProxyManager.shared.isRunning, "\(state)")
            XCTAssertNil(VeilProxyManager.shared.activeRelay, "\(state)")
            XCTAssertNil(VeilProxyManager.shared.activeMethod, "\(state)")
        }
        publish(.veilCooldown(until: Date()))
        XCTAssertTrue(VeilProxyManager.shared.isOnCooldown)
        XCTAssertEqual(VeilProxyManager.shared.currentTrafficPath, .veilCooldown)
        publish(.direct(consecutiveFails: 0))
        XCTAssertFalse(VeilProxyManager.shared.isOnCooldown)
    }

    /// The relay can advertise several methods. Only the runtime's winner is evidence.
    func testTheProbeWinnerSurvivesTrafficAndDrivesFailureClassification() async {
        let previous = TransportRouterMirror.shared.state
        defer { publish(previous) }
        let error = RPCError(code: .unimplemented, message: "Unexpected non-200 HTTP Status Code (404 Not Found)")
        for method in [VeilMethod.webTunnel, .veilFront] {
            let relay = VeilRelay(address: "front.example:443", bridgeCert: "", wtPath: "/ws")
            let effector = NativeProxyEffector(initialRelays: [relay]) { _ in
                VeilProxyEnsureResult(port: 4242, restarted: true, method: method, latencyMs: 1)
            }
            var state = TransportReducer.route(state: .veilProbing, event: await effector.start(), mode: .on, now: Date()).state
            let via = TransportTarget.veil(port: 4242, relay: relay.address)
            for event in [
                TransportEvent.rpcFailed(kind: .streamTimeout, via: via, foreground: true),
                .rpcSucceeded(via: via, latencyMs: 1),
                .streamOpened(method: .veil, via: via)
            ] {
                state = TransportReducer.route(state: state, event: event, mode: .on, now: Date()).state
                XCTAssertEqual(state.veilMethod, method)
            }
            publish(state)

            XCTAssertEqual(VeilProxyManager.shared.activeMethod, method)
            XCTAssertEqual(VeilProxyManager.shared.currentTrafficPath,
                           method == .webTunnel ? .veilWebTunnel(relay: relay.address) : .veilFront(relay: relay.address))
            XCTAssertEqual(RPCFailureClassifier.classify(error, method: state.veilMethod),
                           method == .webTunnel ? .webTunnelBlocked : .applicationError)
            XCTAssertEqual(GRPCChannelManager.sealedFailureKeepsConnection(error, method: state.veilMethod),
                           method != .webTunnel)
        }
    }

    private func publish(_ state: TransportState) {
        let mirror = TransportRouterMirror.shared
        mirror.update(state: state, transition: TransitionLogEntry(
            at: Date(), from: mirror.state, to: state, event: "test", cause: "", effects: []
        ))
    }
}
