//
//  ReceivingInitKindTests.swift
//  ConstructMessengerTests
//
//  `messageNumber == 0` is not "this is an X3DH handshake". After a DH ratchet the new
//  sending chain starts at N=0, and feeding that leftover to `initReceivingSession`
//  fails with "PQ epoch N secret unavailable (current epoch 0)" then clears the pending
//  queue — including any real handshake sitting behind it.
//
//  Device logs 2026-08-19, both sides, six times:
//      msgNum: 0 sealedBox: 283B oneTimePrekeyId: 0 kemCiphertext: 0B
//      → All 1 prekey(s) failed … PQ epoch 2 secret unavailable (current epoch 0)
//  The ephemeral `95ac454b` was a live sending-chain key, not an X3DH ephemeral.
//

import XCTest
@testable import Construct_Messenger

final class ReceivingInitKindTests: XCTestCase {

    private func kind(
        msgNum: UInt32 = 0,
        otpk: UInt32 = 0,
        kem: Int = 0,
        epoch: UInt32 = 0,
        sri: Bool = false
    ) -> SessionReducer.ReceivingInitKind {
        SessionReducer.receivingInitKind(
            messageNumber: msgNum,
            oneTimePreKeyId: otpk,
            kemCiphertextBytes: kem,
            pqMessageEpoch: epoch,
            isSessionResetInit: sri
        )
    }

    /// The field failure: PQ-tagged, no OTPK, no KEM, N=0.
    func testPqEpochLeftover_IsNotAHandshake() {
        XCTAssertEqual(
            kind(epoch: 2),
            .midSessionLeftover,
            "a PQ epoch on a message with no handshake fields is a live sending-chain leftover"
        )
    }

    func testMidRatchet_IsNotAHandshake() {
        XCTAssertEqual(kind(msgNum: 3, epoch: 2), .midRatchet)
        XCTAssertEqual(kind(msgNum: 1), .midRatchet)
    }

    func testOtpkMakesItAHandshakeEvenWithEpoch() {
        XCTAssertEqual(kind(otpk: 1_000_282, kem: 1088, epoch: 0), .handshake)
        XCTAssertEqual(kind(otpk: 1_000_274), .handshake)
    }

    func testKemMakesItAHandshake() {
        XCTAssertEqual(kind(kem: 1088), .handshake)
    }

    func testSessionResetInitIsAlwaysAHandshake() {
        XCTAssertEqual(kind(sri: true), .handshake)
        XCTAssertEqual(kind(epoch: 2, sri: true), .handshake)
    }

    /// 3-DH classic (no OTPK, no KEM, epoch 0) is the reproducible fallback after
    /// `otpkUnreproducible`. Classifying it as a leftover would refuse the one init
    /// that still works when OTPKs are gone.
    func testClassicThreeDH_StaysAHandshake() {
        XCTAssertEqual(kind(), .handshake)
    }

    // MARK: - Carrier pick

    func testPickPrefersTheTriggeringHandshake() {
        let picked = SessionReducer.pickHandshakeCarrier(
            preferred: "sri",
            queued: ["leftover", "otpk"]
        ) { $0 == "leftover" ? .midSessionLeftover : .handshake }
        XCTAssertEqual(picked, "sri")
    }

    func testPickFallsBackToQueuedHandshake() {
        let picked = SessionReducer.pickHandshakeCarrier(
            preferred: "leftover",
            queued: ["also-leftover", "real-otpk"]
        ) { $0.contains("leftover") ? .midSessionLeftover : .handshake }
        XCTAssertEqual(
            picked,
            "real-otpk",
            "init must use the handshake in the queue, not the leftover that triggered the fetch"
        )
    }

    func testPickReturnsNilWhenNothingIsAHandshake() {
        let picked = SessionReducer.pickHandshakeCarrier(
            preferred: "leftover",
            queued: ["another"]
        ) { _ in .midSessionLeftover }
        XCTAssertNil(picked, "calling initReceivingSession with nothing is how the queue gets cleared")
    }
}
