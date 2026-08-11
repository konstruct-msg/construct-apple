//
//  TranscriptSignatureTests.swift
//  ConstructMessengerTests
//
//  The chat flicker, 2026-08-11. One incoming message on a 69-row transcript republished the whole
//  array four times inside one second:
//
//      10:49:20  FRC updated: 69 message(s) in window     ×4
//
//  Four distinct Core Data saves — the insert, then delivery-status writes — each of which changed
//  a fingerprint that hashed `deliveryStatusRaw`, `isEdited`, `timestamp` and `transcriptText`
//  alongside the ids. Every one re-derived the window and reassigned `messages`, and
//  `ChatMessageStore` already carried the note saying what that costs: reassigning "forces
//  LazyVStack identity churn and black flashes". It scales with row count, which is why the
//  flicker only appears once a chat is long — exactly as reported.
//
//  It was also unnecessary: `MessageBubbleRegularView` declares `@ObservedObject var message:
//  Message`, so the row already re-renders itself when its own object changes.
//

import XCTest
@testable import Construct_Messenger

final class TranscriptSignatureTests: XCTestCase {

    private let window = ["a", "b", "c"]

    // MARK: - Must republish

    func testAnInsertChangesTheSignature() {
        XCTAssertNotEqual(TranscriptSignature.of(ids: window), TranscriptSignature.of(ids: ["a", "b", "c", "d"]))
    }

    func testADeleteChangesTheSignature() {
        XCTAssertNotEqual(TranscriptSignature.of(ids: window), TranscriptSignature.of(ids: ["a", "c"]))
    }

    func testAReorderChangesTheSignature() {
        // A timestamp edit re-sorts the fetch. The signature drops `timestamp` precisely because
        // the re-sort shows up here instead.
        XCTAssertNotEqual(TranscriptSignature.of(ids: window), TranscriptSignature.of(ids: ["a", "c", "b"]))
    }

    func testAReplacementOfTheSameLengthChangesTheSignature() {
        // Same count, different rows — count alone would miss this.
        XCTAssertNotEqual(TranscriptSignature.of(ids: window), TranscriptSignature.of(ids: ["a", "b", "z"]))
    }

    // MARK: - Must NOT republish

    func testTheSameRowsInTheSameOrderAreTheSameSignature() {
        // The whole fix: delivery status, edit flag and a transcript landing after speech-to-text
        // all change a row without changing the row set, and each of them used to rebuild 69 rows.
        XCTAssertEqual(TranscriptSignature.of(ids: window), TranscriptSignature.of(ids: ["a", "b", "c"]))
    }

    func testRepeatedIdenticalWindowsNeverDrift() {
        // Four saves in one second was the observed burst; none of them may republish now.
        let first = TranscriptSignature.of(ids: window)
        for _ in 0..<4 {
            XCTAssertEqual(TranscriptSignature.of(ids: window), first)
        }
    }

    func testAnEmptyWindowIsStableAndDistinctFromAPopulatedOne() {
        XCTAssertEqual(TranscriptSignature.of(ids: []), TranscriptSignature.of(ids: []))
        XCTAssertNotEqual(TranscriptSignature.of(ids: []), TranscriptSignature.of(ids: ["a"]))
    }
}
