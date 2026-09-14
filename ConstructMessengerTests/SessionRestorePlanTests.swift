//
//  SessionRestorePlanTests.swift
//  ConstructMessengerTests
//
//  Which sessions come back into the core at launch.
//
//  ## The defect
//
//  The answer was `chats.compactMap { $0.otherUser?.id }` and nothing else, so *which sessions
//  exist* was inferred from the chat list — an account-space list. A session keyed by a
//  `CryptoDeviceId` has no `Chat` row and no `User` row, so none of them was ever restored, and
//  that is every session with one of our own devices.
//
//  Three-device run, 2026-08-30. The desktop held a live session with the phone's device
//  `b26a2cf8` and saved it all morning. After a relaunch:
//
//      11:04:55  Restored session (CFE): 7574fdec-ca31-44ac-9d43-0e6e870fe4d5
//      11:04:55  Session restore: 1 restored, 0 failed
//      11:06:22  SENDER_SYNC: no own-device session opened … messageNumber=1 > 0 — dropping
//      11:06:23  … messageNumber=3 > 0 — dropping
//      11:06:50  … messageNumber=5 > 0 — dropping
//
//  The drop is unrecoverable by design: only a `messageNumber == 0` copy can establish an
//  own-device session, and the sender has no reason to send another one. So the second device
//  received its own account's messages until it was restarted, and never again — which is exactly
//  the shape the symptom took, twice, and why fixing the sender's mirror did not fix it.
//
//  This is the same defect the repository is named after: one meaning — the set of sessions —
//  carried by two things, and the one being read was not the authority.
//

import XCTest
@testable import Construct_Messenger

final class SessionRestorePlanTests: XCTestCase {

    private let peerAccount = "7574fdec-ca31-44ac-9d43-0e6e870fe4d5"
    private let ourPhone    = "b26a2cf863f7db482ed0f2963933b86c"
    private let peerDevice  = "651e765cbbd33b4e48631fb802c2b3d2"

    /// The one that was missing. A device-shaped session has no chat, so the chat list can never
    /// name it — and it is the only kind whose absence nothing later repairs.
    ///
    /// Mutation: return `recentChatContacts` alone — this reddens.
    func testASessionWithNoChatIsStillRestored() {
        let ordered = SessionRestorePlan.make(
            recentChatContacts: [peerAccount],
            liveSessionContacts: [peerAccount, ourPhone]
        ).contactIds
        XCTAssertTrue(ordered.contains(ourPhone),
                      "an own-device session has no Chat row; leaving it out is what dropped every SENDER_SYNC after a relaunch")
        XCTAssertEqual(ordered.count, 2, "the peer account must not be restored twice")
    }

    /// Recency still decides what comes first: the cap on the chat query exists so a long history
    /// does not make launch slow, and the user's newest conversation should be ready first.
    ///
    /// Mutation: append the store's list before the chats' — this reddens.
    func testRecentChatsComeFirst() {
        let ordered = SessionRestorePlan.make(
            recentChatContacts: [peerAccount],
            liveSessionContacts: [ourPhone, peerDevice, peerAccount]
        ).contactIds
        XCTAssertEqual(ordered.first, peerAccount)
    }

    /// A contact named by both lists is restored once. Restoring twice is not harmful, but the
    /// count in the log is what a reader uses to tell "the chat list could not name these" from
    /// "these were counted twice".
    ///
    /// Mutation: drop the `seen` set — this reddens.
    func testNothingIsRestoredTwice() {
        let plan = SessionRestorePlan.make(
            recentChatContacts: [peerAccount, ourPhone],
            liveSessionContacts: [ourPhone, peerAccount, peerDevice]
        )
        XCTAssertEqual(plan.contactIds, [peerAccount, ourPhone, peerDevice])
        // The split is what the log reports, and a reader uses it to tell "the chat list could
        // not name these" from "these were counted twice".
        XCTAssertEqual(plan.fromChats, 2)
        XCTAssertEqual(plan.fromSessionStore, 1)
    }

    func testEmptyIdsAreIgnored() {
        let ordered = SessionRestorePlan.make(
            recentChatContacts: ["", peerAccount],
            liveSessionContacts: ["", ourPhone]
        ).contactIds
        XCTAssertEqual(ordered, [peerAccount, ourPhone])
    }

    /// With nothing on disk the plan is what it always was, so a device with no sessions does not
    /// suddenly start restoring things the chat list invented.
    func testWithNoSessionsOnDiskThePlanIsTheChatList() {
        XCTAssertEqual(
            SessionRestorePlan.make(recentChatContacts: [peerAccount], liveSessionContacts: []).contactIds,
            [peerAccount]
        )
    }
}

/// An archive is not a session to restore.
///
/// `isSessionState` accepts both on purpose — the wipe must reach both — so the restore reader
/// needs the narrower predicate. Restoring from an archive account would look up a live blob that
/// is not there and count a failure for every peer that ever had a session reset.
final class LiveSessionAccountTests: XCTestCase {

    func testALiveSessionAccountIsLive() {
        XCTAssertTrue(KeychainSessionAccounts.isLiveSession("session_b26a2cf863f7db482ed0f2963933b86c"))
        XCTAssertTrue(KeychainSessionAccounts.isLiveSession("session_7574fdec-ca31-44ac-9d43-0e6e870fe4d5"))
    }

    /// Mutation: drop the archive check from `isLiveSession` — this reddens.
    func testAnArchiveIsNot() {
        XCTAssertFalse(KeychainSessionAccounts.isLiveSession("session_archives_b26a2cf863f7db482ed0f2963933b86c"))
        XCTAssertTrue(KeychainSessionAccounts.isSessionState("session_archives_b26a2cf863f7db482ed0f2963933b86c"),
                      "the wipe still has to reach archives — that predicate stays wider on purpose")
    }

    func testSomethingElseInTheNamespaceIsNot() {
        XCTAssertFalse(KeychainSessionAccounts.isLiveSession("session_token"))
        XCTAssertFalse(KeychainSessionAccounts.isLiveSession("deviceId"))
    }
}
