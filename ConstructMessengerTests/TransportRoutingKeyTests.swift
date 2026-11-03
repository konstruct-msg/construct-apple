//
//  TransportRoutingKeyTests.swift
//  ConstructMessengerTests
//
//  The routing key the channel manager writes must be the one the stream loop reads. From
//  2026-05-30 to 2026-11-03 the writer said `ice:<port>` and the stream-failure readers checked
//  `veil:`, so a VEIL stream failure reached the router as `via: .direct(.h2)` with no VEIL
//  method: no client invalidation in `veilActive`, and "direct failed this session" set by a
//  failure that never touched the direct path.
//

import XCTest
@testable import Construct_Messenger

final class TransportRoutingKeyTests: XCTestCase {

    override func tearDown() {
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        super.tearDown()
    }

    private let veilState = TransportState.veilActive(
        relay: "relay.test:443", port: 54321, since: Date(timeIntervalSince1970: 0), method: .webTunnel
    )

    /// The key the manager writes while the proxy is up is read back as VEIL, and a failure on
    /// it goes to the router as a VEIL failure with the probe winner.
    func testAFailureOnTheVeilKeyTheManagerWritesIsAVeilFailure() {
        GRPCChannelManager.shared.setDirectProxyPort(54321)
        let key = GRPCChannelManager.shared.currentRoutingKey

        XCTAssertTrue(TransportRoutingKey.isVeil(key), key)
        XCTAssertFalse(TransportRoutingKey.isDirect(key), key)
        let route = TransportRoutingKey.failureRoute(key: key, veilPort: 54321, state: veilState)
        XCTAssertEqual(route.via, .veil(port: 54321, relay: "relay.test:443"))
        XCTAssertEqual(route.veilMethod, .webTunnel)
    }

    func testAFailureOnTheDirectKeyIsADirectFailureWithoutAVeilMethod() {
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        let key = GRPCChannelManager.shared.currentRoutingKey

        XCTAssertTrue(TransportRoutingKey.isDirect(key), key)
        XCTAssertFalse(TransportRoutingKey.isVeil(key), key)
        let route = TransportRoutingKey.failureRoute(key: key, veilPort: nil, state: veilState)
        XCTAssertEqual(route.via, .direct(.h2))
        XCTAssertNil(route.veilMethod)
    }
}
