//
//  IntakeCredentialTests.swift
//  ConstructMessengerTests
//
//  The publishing window is the half of the intake credential that fails quietly.
//
//  What this device publishes is what *its contacts* present to be let through without a token, so
//  a window that drains does not degrade this device at all — it silently puts everyone who writes
//  to us back on the wallet, and the only visible trace is a token bill on somebody else's phone.
//  Nothing on this side goes red. That is why the two decisions below are pinned here rather than
//  left as arithmetic at the call site.
//
import XCTest
@testable import Construct_Messenger

final class IntakePublishingTests: XCTestCase {

    func testTheWindowStartsTodayNotTomorrow() {
        // A fresh install has published nothing and its first incoming message is due today. A
        // window starting at currentEpoch + 1 would leave the whole first day unvouched, which is
        // exactly the day a new contact writes.
        let epochs = IntakePublishing.epochsToPublish(currentEpoch: 20_707)
        XCTAssertEqual(epochs.first, 20_707)
        XCTAssertEqual(epochs.count, IntakePublishing.windowEpochs)
        XCTAssertEqual(epochs.last, 20_707 + UInt64(IntakePublishing.windowEpochs) - 1)
    }

    func testTheWindowIsContiguous() {
        // A gap is a day on which our contacts pay and nothing here says why.
        let epochs = IntakePublishing.epochsToPublish(currentEpoch: 100)
        XCTAssertEqual(epochs, Array(100...(100 + UInt64(IntakePublishing.windowEpochs) - 1)))
    }

    func testTheWindowFitsTheServerCap() {
        // messaging-service takes at most 14 entries per call and drops the rest silently. A
        // window longer than that would publish a tail nobody stores.
        XCTAssertLessThanOrEqual(IntakePublishing.windowEpochs, 14)
    }

    func testTheWindowSurvivesADeviceThatWasOfflineForDays() {
        // A second device is routinely dark for a week. If the window were shorter than that, its
        // own incoming traffic would start paying while it slept.
        XCTAssertGreaterThanOrEqual(IntakePublishing.windowEpochs, 7)
    }

    func testAFreshInstallPublishes() {
        XCTAssertTrue(IntakePublishing.shouldPublish(lastPublishedEpoch: nil, currentEpoch: 20_707))
    }

    func testTheSameEpochDoesNotPublishTwice() {
        // Every launch otherwise spends an authenticated RPC on a hot path for no new tags.
        XCTAssertFalse(IntakePublishing.shouldPublish(lastPublishedEpoch: 20_707, currentEpoch: 20_707))
    }

    func testANewEpochPublishesAgain() {
        XCTAssertTrue(IntakePublishing.shouldPublish(lastPublishedEpoch: 20_707, currentEpoch: 20_708))
    }

    func testAClockThatWentBackwardsPublishesRatherThanSkipping() {
        // `last > current` means we cannot reason about the window at all. Publishing costs one
        // RPC; skipping costs every contact a token for as long as the confusion lasts, so the
        // comparison is inequality and deliberately not `current > last`.
        XCTAssertTrue(IntakePublishing.shouldPublish(lastPublishedEpoch: 20_710, currentEpoch: 20_707))
    }
}

/// Why an envelope paid a token.
///
/// Until 2026-09-14 all four causes returned the same silent nil, so the device log said
/// "sealed send WITH token" and nothing more. On 2026-09-13 the server counted 8 envelopes as
/// `absent` and the device logs could not say which cause it was — the reason these are named.
final class IntakeTagAbsenceTests: XCTestCase {

    /// The ordinary rollout state, and the answer to "why did this pay". A peer's key arrives the
    /// first time they write to us; until then every envelope to them buys a token.
    func testNoStoredKeyIsTheOrdinaryCause() {
        XCTAssertEqual(IntakeTagAbsence.forStoredKey(nil), .noKeyForPeer)
    }

    /// A usable key is the one case that is not an absence at all.
    func testAThirtyTwoByteKeyIsUsable() {
        XCTAssertNil(IntakeTagAbsence.forStoredKey(Data(repeating: 7, count: 32)))
    }

    /// Corruption, not a bad sender: `recordPeerIntakeKey` refuses to write a key of the wrong
    /// size, so reading one back means the stored item was damaged. Collapsing this into
    /// `noKeyForPeer` would file a malfunction under the one cause nobody investigates.
    func testAWrongSizedStoredKeyIsNotTheSameAsNoKey() {
        for size in [0, 1, 16, 31, 33, 64] {
            XCTAssertEqual(
                IntakeTagAbsence.forStoredKey(Data(repeating: 7, count: size)),
                .storedKeyWrongSize,
                "a \(size)-byte stored key is corruption, not an absent one"
            )
        }
        XCTAssertNotEqual(
            IntakeTagAbsence.forStoredKey(Data(repeating: 7, count: 31)),
            IntakeTagAbsence.forStoredKey(nil)
        )
    }

    /// The raw values reach the log and are what someone greps for. Distinct, and stable.
    func testEveryCauseHasItsOwnName() {
        let all: [IntakeTagAbsence] = [.noKeyForPeer, .storedKeyWrongSize, .derivationFailed, .sealingFailed]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        XCTAssertEqual(IntakeTagAbsence.noKeyForPeer.rawValue, "no_key_for_peer")
        XCTAssertEqual(IntakeTagAbsence.storedKeyWrongSize.rawValue, "stored_key_wrong_size")
        XCTAssertEqual(IntakeTagAbsence.derivationFailed.rawValue, "derivation_failed")
        XCTAssertEqual(IntakeTagAbsence.sealingFailed.rawValue, "sealing_failed")
    }
}
