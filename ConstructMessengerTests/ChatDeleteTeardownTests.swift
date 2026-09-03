import XCTest
@testable import Construct_Messenger

/// Deleting a chat clears this device. Whether it also asks the peer to tear the session down is a
/// separate question, and until delivery names the sending device (§D) the answer is "only if we
/// are alone on the account".
///
/// 2026-09-03: a Desktop linked minutes earlier opened a chat that post-link history sync had left
/// empty, deleted it, and the peer archived the **iPhone's** session — every one of the six
/// archives that run landed on a device that had asked for nothing. A secondary device deleting a
/// chat could destroy the primary's healthy session.
final class ChatDeleteTeardownTests: XCTestCase {

    /// The only case that may announce: nobody else on the account can be hurt by the peer
    /// applying it to the wrong device, because there is no other device.
    func testASingleDeviceAccountAnnouncesTheTeardown() {
        XCTAssertTrue(ChatsViewModel.mayAnnounceTeardown(ownDeviceCount: 1))
    }

    /// **The case this exists for.** A sibling exists, delivery cannot say which device asked, so
    /// the peer would resolve it to its pinned device — which may be the sibling.
    func testAnAccountWithASiblingDoesNot() {
        XCTAssertFalse(ChatsViewModel.mayAnnounceTeardown(ownDeviceCount: 2))
        XCTAssertFalse(ChatsViewModel.mayAnnounceTeardown(ownDeviceCount: 5))
    }

    /// Unknown is not "alone". The two mistakes are not symmetrical: announcing when a sibling
    /// exists destroys a healthy session on the peer, while withholding leaves the peer holding a
    /// ratchet nothing will use. A failed device-set fetch must fall to the second.
    func testAnUnknownDeviceCountIsTreatedAsHavingASibling() {
        XCTAssertFalse(ChatsViewModel.mayAnnounceTeardown(ownDeviceCount: nil))
    }

    /// Zero is not a real answer either — an account always has the device asking the question —
    /// so it means the fetch came back empty and must be read the same way as `nil`.
    func testZeroIsNotAnAnswer() {
        XCTAssertFalse(
            ChatsViewModel.mayAnnounceTeardown(ownDeviceCount: 0),
            "an empty set is a failed fetch, not a device-less account"
        )
    }
}
