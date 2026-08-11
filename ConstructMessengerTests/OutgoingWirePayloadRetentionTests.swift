//
//  OutgoingWirePayloadRetentionTests.swift
//  ConstructMessengerTests
//
//  The incident: NSUserDefaults grew past the 4 MB CFPreferences limit on a real device
//  (2026-08-11 15:21:25, "Attempting to store >= 4194304 bytes … This is a bug in Construct
//  Messenger or a library it uses"). `OutgoingWirePayloadStore` writes one key per outgoing
//  message and gave it a 24h TTL that was only evaluated when that same key was read back — so a
//  message nobody retried kept its encrypted payload forever.
//

import XCTest
@testable import Construct_Messenger

final class OutgoingWirePayloadRetentionTests: XCTestCase {

    private let ttl: TimeInterval = 24 * 60 * 60
    private let now: TimeInterval = 1_786_450_885   // the device timestamp above

    // MARK: - What must be swept

    /// The leak that actually filled the domain: the app is killed between `onWirePayloadEncoded`
    /// and the server's answer, so no success or failure path is left to remove the key.
    func testPayloadOrphanedByAKilledSendIsSweptAfterTtl() {
        let expired = OutgoingWirePayloadRetention.expiredKeys(
            entries: [("construct.outgoingWirePayload.5b1d7b0c", now - ttl - 1)],
            now: now,
            ttl: ttl
        )
        XCTAssertEqual(expired, ["construct.outgoingWirePayload.5b1d7b0c"])
    }

    /// An entry that will not decode can never be re-sent and can never purge itself, so keeping it
    /// only preserves bytes nobody can use.
    func testUndecodableEntryIsSwept() {
        let expired = OutgoingWirePayloadRetention.expiredKeys(
            entries: [("construct.outgoingWirePayload.corrupt", nil)],
            now: now,
            ttl: ttl
        )
        XCTAssertEqual(expired, ["construct.outgoingWirePayload.corrupt"])
    }

    // MARK: - What must NOT be swept

    /// A retryable transport failure parks the message as `.queued` and keeps its payload on
    /// purpose. Deleting it would be worse than the leak: the retry would have to re-encrypt,
    /// which advances the Double Ratchet and breaks decryption on the peer.
    func testQueuedRetryWithinTtlIsKept() {
        let expired = OutgoingWirePayloadRetention.expiredKeys(
            entries: [("construct.outgoingWirePayload.live", now - 3600)],
            now: now,
            ttl: ttl
        )
        XCTAssertTrue(expired.isEmpty, "a payload one hour old is still the only safe way to retry")
    }

    /// Exactly at the TTL is still inside it — the boundary is `>`, not `>=`, so a sweep that runs
    /// the same instant a payload turns 24h does not race it away.
    func testPayloadExactlyAtTtlIsKept() {
        let expired = OutgoingWirePayloadRetention.expiredKeys(
            entries: [("construct.outgoingWirePayload.boundary", now - ttl)],
            now: now,
            ttl: ttl
        )
        XCTAssertTrue(expired.isEmpty)
    }

    /// The user edits their timezone or NTP corrects the clock backwards, and every live queued
    /// payload suddenly looks like it was created in the future. Treating "future" as "ancient"
    /// would delete precisely the messages still waiting to go out.
    func testClockMovedBackwardsDoesNotDeleteALiveRetry() {
        let expired = OutgoingWirePayloadRetention.expiredKeys(
            entries: [("construct.outgoingWirePayload.future", now + 7200)],
            now: now,
            ttl: ttl
        )
        XCTAssertTrue(expired.isEmpty)
    }

    // MARK: - Mixed

    func testSweepTakesOnlyTheDeadOnes() {
        let expired = OutgoingWirePayloadRetention.expiredKeys(
            entries: [
                ("construct.outgoingWirePayload.old", now - ttl - 1),
                ("construct.outgoingWirePayload.live", now - 60),
                ("construct.outgoingWirePayload.broken", nil),
                ("construct.outgoingWirePayload.future", now + 1),
            ],
            now: now,
            ttl: ttl
        )
        XCTAssertEqual(
            Set(expired),
            ["construct.outgoingWirePayload.old", "construct.outgoingWirePayload.broken"]
        )
    }

    /// The prefix is shared between the store's key builder and the sweep. Two spellings would
    /// sweep nothing while looking perfectly correct.
    func testKeyPrefixMatchesWhatTheStoreWrites() {
        XCTAssertEqual(OutgoingWirePayloadRetention.keyPrefix, "construct.outgoingWirePayload.")
    }
}
