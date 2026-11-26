#if os(iOS)
import CallKit
import XCTest
@testable import Construct_Messenger

/// A call stays out of the Phone app's Recents: that list syncs through iCloud and would hold who
/// called whom and when. CallKit includes calls unless told otherwise.
final class CallKitConfigurationTests: XCTestCase {
    func testCallsStayOutOfTheSystemRecents() {
        XCTAssertFalse(CallKitProvider.configuration().includesCallsInRecents)
    }

    func testTheConfigurationStillCarriesVideoAndOneCall() {
        let config = CallKitProvider.configuration()
        XCTAssertTrue(config.supportsVideo)
        XCTAssertEqual(config.maximumCallGroups, 1)
        XCTAssertEqual(config.maximumCallsPerCallGroup, 1)
        XCTAssertEqual(config.supportedHandleTypes, [.generic])
    }
}
#endif
