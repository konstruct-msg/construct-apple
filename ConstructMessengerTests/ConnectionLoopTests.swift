import XCTest
@testable import Construct_Messenger

final class ConnectionLoopTests: XCTestCase {
    override func setUp() {
        super.setUp()
        VeilProxyStore.saveMode(.auto)
        VeilProxyStore.clearStoredRelay()
        VeilProxyStore.lastSuccessfulPath = nil
        WebTunnelPenaltyStore.save([:])
    }

    override func tearDown() {
        VeilProxyStore.saveMode(.auto)
        VeilProxyStore.clearStoredRelay()
        VeilProxyStore.lastSuccessfulPath = nil
        WebTunnelPenaltyStore.save([:])
        super.tearDown()
    }

    func testVeilMode_roundTripsThroughStore() {
        VeilProxyStore.saveMode(.on)
        XCTAssertEqual(VeilProxyStore.loadMode(), .on)

        VeilProxyStore.saveMode(.off)
        XCTAssertEqual(VeilProxyStore.loadMode(), .off)
    }

    func testWebTunnelPenaltyStore_roundTripsValues() {
        let penalty = ["a.test:443": 5, "b.test:443": 11]
        WebTunnelPenaltyStore.save(penalty)
        XCTAssertEqual(WebTunnelPenaltyStore.load(), penalty)
    }

    func testLastSuccessfulPath_canBeSetAndCleared() {
        VeilProxyStore.lastSuccessfulPath = "veil:a.test:443"
        XCTAssertEqual(VeilProxyStore.lastSuccessfulPath, "veil:a.test:443")

        VeilProxyStore.lastSuccessfulPath = nil
        XCTAssertNil(VeilProxyStore.lastSuccessfulPath)
    }
}
