import XCTest
@testable import Construct_Messenger

final class GRPCCallExecutorTests: XCTestCase {
    func testVeilProxyPort_nilWhenNoPortSet() {
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        XCTAssertNil(GRPCChannelManager.shared.veilProxyPort())
    }

    func testVeilProxyPort_nonNilAfterSetDirectProxyPort() {
        GRPCChannelManager.shared.setDirectProxyPort(54321)
        XCTAssertNotNil(GRPCChannelManager.shared.veilProxyPort())
        GRPCChannelManager.shared.setDirectProxyPort(nil)
    }

    func testVeilProxyPort_nilAfterPortCleared() {
        GRPCChannelManager.shared.setDirectProxyPort(54321)
        GRPCChannelManager.shared.setDirectProxyPort(nil)
        XCTAssertNil(GRPCChannelManager.shared.veilProxyPort())
    }
}
