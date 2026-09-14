//
//  ResponderFinalizeContactIdTests.swift
//  ConstructMessengerTests
//
//  A RESPONDER init finishes by telling the core which device the session belongs to. Naming that
//  device by looking it up in the contact list is wrong in exactly the case the code always runs
//  in: first contact, when nothing is pinned yet.
//
//  Devices 2026-09-04 09:38:21 — one account and one device on each side, so no multi-device
//  ambiguity to hide behind. Inside one second:
//
//      init_receiving_start: userId=ffeeddc6…
//      Session initialized successfully, decrypted 46B
//      init_receiving_success: userId=ffeeddc6…, duration=0.02s
//      Successfully saved decrypted pending message
//      No pinned identity key for ffeeddc6… — cannot name a device   ← the lookup fails
//      init_completed_finalize_failed: No session found … ffeeddc6…  ← reported as "no session"
//      Sending END_SESSION to ffeeddc6… : session_init_completed_failed
//
//  One second later the peer answered with `initiator_announce (end_session_received)` and spent
//  another one-time prekey. The session was never missing. Nothing could name it, and the `catch`
//  could not tell those apart.
//
//  `SessionAddressing.cryptoIdentity(ofIdentityKey:)` already documents the rule these tests pin:
//  the key in hand is "the only one that answers at first contact". The finalize path had the
//  device derived from that key sitting in a local variable and asked the contact list instead.
//

import XCTest
@testable import Construct_Messenger

final class ResponderFinalizeContactIdTests: XCTestCase {

    /// A device id shaped like the real thing: `deriveDeviceId` of an identity key, 32 hex chars.
    private func device(_ byte: UInt8) -> String {
        deriveDeviceId(identityPublicKey: [UInt8](Data(repeating: byte, count: 32)))
    }

    // MARK: - The defect, stated

    /// **The production bug in one line.** First contact: the session opened against a device we
    /// derived from the bundle, and the contact list has nothing pinned. The old order asked the
    /// contact list only, got `nil`, and reported a healthy session as missing.
    func testAnOpenedDeviceAnswersWhenNothingIsPinned() {
        let opened = device(0x11)
        XCTAssertEqual(
            SessionCoordinator.finalizeContactId(openedDevice: opened, pinnedDevice: nil),
            opened,
            "a session that just opened must be nameable before its peer's key is pinned"
        )
    }

    /// The same statement from the other side: with an opened device present, the answer never
    /// depends on the pinned row — including when the pinned row names a *different* device.
    /// Preferring the pin there would hand the core a device this session was not built against.
    func testTheOpenedDeviceWinsOverAContradictoryPin() {
        let opened = device(0x11)
        let pinned = device(0x22)
        XCTAssertNotEqual(opened, pinned, "pre-condition: the two devices are distinct")
        XCTAssertEqual(
            SessionCoordinator.finalizeContactId(openedDevice: opened, pinnedDevice: pinned),
            opened
        )
    }

    // MARK: - The fallback, and its limit

    func testThePinAnswersWhenNoDeviceWasOpened() {
        let pinned = device(0x33)
        XCTAssertEqual(
            SessionCoordinator.finalizeContactId(openedDevice: nil, pinnedDevice: pinned),
            pinned
        )
    }

    /// `nil` is the honest answer when neither half names a device — the state in which the core
    /// has nothing to be told about. It must stay reachable: a helper that always answered would
    /// hand the core an empty contact id instead of letting the caller decline.
    func testNeitherHalfMeansNoAnswer() {
        XCTAssertNil(SessionCoordinator.finalizeContactId(openedDevice: nil, pinnedDevice: nil))
    }

    /// An empty string is not a device id, and it reads as one at every `!= nil` downstream.
    /// Both slots are normalised, and an empty opened device falls through to the pin rather than
    /// swallowing it.
    func testAnEmptyIdIsNoId() {
        let pinned = device(0x44)
        XCTAssertEqual(
            SessionCoordinator.finalizeContactId(openedDevice: "", pinnedDevice: pinned),
            pinned,
            "an empty opened device must not shadow a usable pin"
        )
        XCTAssertNil(SessionCoordinator.finalizeContactId(openedDevice: "", pinnedDevice: ""))
        XCTAssertNil(SessionCoordinator.finalizeContactId(openedDevice: nil, pinnedDevice: ""))
    }

    // MARK: - The space, not just the value

    /// Whatever comes back is a `CryptoDeviceId` — the space the core keys sessions by. An account
    /// UUID reaching `sessionInitCompleted` is the seam defect this codebase keeps paying for, so
    /// the helper must never turn one into an answer.
    func testTheAnswerIsAlwaysADeviceId() {
        let opened = device(0x11)
        let pinned = device(0x22)
        let answers = [
            SessionCoordinator.finalizeContactId(openedDevice: opened, pinnedDevice: nil),
            SessionCoordinator.finalizeContactId(openedDevice: nil, pinnedDevice: pinned),
            SessionCoordinator.finalizeContactId(openedDevice: opened, pinnedDevice: pinned)
        ].compactMap { $0 }

        XCTAssertEqual(answers.count, 3, "all three cases must answer, or this test reads nothing")
        for answer in answers {
            XCTAssertTrue(
                SessionAddressing.isCryptoIdentity(answer),
                "\(answer) is not a CryptoDeviceId — the core keys sessions by device"
            )
        }
    }
}
