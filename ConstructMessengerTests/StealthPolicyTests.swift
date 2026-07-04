import XCTest
@testable import Construct_Messenger

/// stealth-sealed-sender-v2 Phase 4: StealthPolicy.isEnabled is always true in Release;
/// DEBUG builds (which is what tests run under) keep a UserDefaults-backed override so
/// engineers can exercise the legacy identified-send path without recompiling.
@MainActor
final class StealthPolicyTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "stealth_mode_enabled")
        super.tearDown()
    }

    func testIsEnabled_defaultsToTrueWhenKeyUnset() {
        UserDefaults.standard.removeObject(forKey: "stealth_mode_enabled")
        XCTAssertTrue(StealthPolicy.shared.isEnabled)
    }

    func testIsEnabled_respectsExplicitFalseOverride() {
        UserDefaults.standard.set(false, forKey: "stealth_mode_enabled")
        XCTAssertFalse(StealthPolicy.shared.isEnabled)
    }

    func testIsEnabled_respectsExplicitTrueOverride() {
        UserDefaults.standard.set(true, forKey: "stealth_mode_enabled")
        XCTAssertTrue(StealthPolicy.shared.isEnabled)
    }

    func testShouldUseSealedSender_matchesIsEnabled() {
        UserDefaults.standard.set(false, forKey: "stealth_mode_enabled")
        XCTAssertEqual(StealthPolicy.shared.shouldUseSealedSender(), StealthPolicy.shared.isEnabled)

        UserDefaults.standard.set(true, forKey: "stealth_mode_enabled")
        XCTAssertEqual(StealthPolicy.shared.shouldUseSealedSender(), StealthPolicy.shared.isEnabled)
    }
}
