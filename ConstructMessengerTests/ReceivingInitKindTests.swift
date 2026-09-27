//
//  ReceivingInitKindTests.swift
//  ConstructMessengerTests
//
//  Which message can open a receiving session, as this app asks the core.
//
//  Since 2026-09-27 the answer is the handshake header — the KEM ciphertext — at any message
//  number: the initiator repeats it on every message until the peer answers, so a lost first
//  message costs nothing (`decisions/sessions-renew-by-sending.md`). Until then it was "message
//  number 0 unless a PQ epoch says otherwise", and a bare message 0 was a handshake — which is
//  what a DH sending chain restarting at 0 also looks like (device logs 2026-08-19: `msgNum: 0
//  oneTimePrekeyId: 0 kemCiphertext: 0B` → "PQ epoch 2 secret unavailable").
//
//  The rule is the core's (`receiving_init_plan.rs`); these pin the forwarder and that the app's
//  core is built with PQXDH, which is what makes the KEM ciphertext the whole rule.
//

import XCTest
@testable import Construct_Messenger

final class ReceivingInitKindTests: XCTestCase {

    private func kind(
        msgNum: UInt32 = 0,
        otpk: UInt32 = 0,
        kem: Int = 0,
        epoch: UInt32 = 0
    ) -> SessionReducer.ReceivingInitKind {
        SessionReducer.receivingInitKind(
            messageNumber: msgNum,
            oneTimePreKeyId: otpk,
            kemCiphertextBytes: kem,
            pqMessageEpoch: epoch
        )
    }

    /// The change of 2026-09-27: a header past message 0 opens.
    func testAHeaderOpensAtAnyMessageNumber() {
        XCTAssertEqual(kind(msgNum: 0, kem: 1568), .handshake)
        XCTAssertEqual(kind(msgNum: 5, kem: 1568), .handshake)
    }

    /// The field failure of 2026-08-19, and a bare message 0 generally: a DH chain restarting,
    /// not an opener. There is no classical handshake to mistake it for any more.
    func testABareFirstMessageIsNotAHandshake() {
        XCTAssertEqual(kind(epoch: 2), .midRatchet)
        XCTAssertEqual(kind(), .midRatchet)
    }

    func testMidRatchet_IsNotAHandshake() {
        XCTAssertEqual(kind(msgNum: 3, epoch: 2), .midRatchet)
        XCTAssertEqual(kind(msgNum: 1), .midRatchet)
    }

    /// A one-time pre-key id without a KEM ciphertext is not a PQXDH handshake.
    func testAnOtpkAloneIsNotAHandshake() {
        XCTAssertEqual(kind(otpk: 1_000_274), .midRatchet)
    }
}
