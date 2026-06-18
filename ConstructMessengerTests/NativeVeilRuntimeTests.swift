import XCTest
@testable import Construct_Messenger

final class NativeVeilRuntimeTests: XCTestCase {
    func testVeilFrontOnlyBitmaskDisablesLegacyMethods() {
        let mask = NativeVeilRuntime.veilFrontOnlyDisabledMethodsBitmask

        XCTAssertNotEqual(mask & (UInt32(1) << UInt32(VeilMethod.obfs4.rawValue)), 0)
        XCTAssertNotEqual(mask & (UInt32(1) << UInt32(VeilMethod.webTunnel.rawValue)), 0)
        XCTAssertNotEqual(mask & (UInt32(1) << UInt32(VeilMethod.masque.rawValue)), 0)
        XCTAssertEqual(mask & (UInt32(1) << UInt32(VeilMethod.veilFront.rawValue)), 0)
    }
}
