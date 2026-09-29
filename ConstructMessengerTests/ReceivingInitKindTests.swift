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
//  The rule is the core's (`receiving_init_plan.rs`), asked through `wire_summary` from the
//  payload bytes — the one parse this app makes of a received message. These pin that the answer
//  comes from the header as the core reads it, and that the app's core is built with PQXDH.
//

import XCTest
@testable import Construct_Messenger

final class ReceivingInitKindTests: XCTestCase {

    private func kind(
        msgNum: UInt32 = 0,
        kem: Int = 0,
        epoch: UInt32 = 0
    ) throws -> ReceivingInitKind {
        let payload = handBuiltWirePayload(
            messageNumber: msgNum,
            suiteId: 3,
            kemCiphertext: kem > 0 ? [UInt8](repeating: 5, count: kem) : nil,
            pqMessageEpoch: epoch
        )
        let summary = try wireSummary(wirePayload: payload)
        XCTAssertEqual(summary.messageNumber, msgNum, "the number is read from the header")
        return summary.initKind
    }

    /// The change of 2026-09-27: a header past message 0 opens.
    func testAHeaderOpensAtAnyMessageNumber() throws {
        XCTAssertEqual(try kind(msgNum: 0, kem: 1568), .handshake)
        XCTAssertEqual(try kind(msgNum: 5, kem: 1568), .handshake)
    }

    /// The field failure of 2026-08-19, and a bare message 0 generally: a DH chain restarting,
    /// not an opener. There is no classical handshake to mistake it for any more.
    func testABareFirstMessageIsNotAHandshake() throws {
        XCTAssertEqual(try kind(epoch: 2), .midRatchet)
        XCTAssertEqual(try kind(), .midRatchet)
    }

    func testMidRatchet_IsNotAHandshake() throws {
        XCTAssertEqual(try kind(msgNum: 3, epoch: 2), .midRatchet)
        XCTAssertEqual(try kind(msgNum: 1), .midRatchet)
    }

    /// A payload the core cannot parse has no summary: it can open nothing, and the parser
    /// refuses it before routing.
    func testAnUnparseablePayloadHasNoSummary() {
        XCTAssertThrowsError(try wireSummary(wirePayload: Data(repeating: 0xFF, count: 7)))
    }
}
