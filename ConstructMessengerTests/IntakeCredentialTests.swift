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
        let all: [IntakeTagAbsence] = [
            .noKeyForPeer, .storedKeyWrongSize, .derivationFailed, .sealingFailed, .rejectedThisEpoch
        ]
        XCTAssertEqual(Set(all.map(\.rawValue)).count, all.count)
        XCTAssertEqual(IntakeTagAbsence.noKeyForPeer.rawValue, "no_key_for_peer")
        XCTAssertEqual(IntakeTagAbsence.storedKeyWrongSize.rawValue, "stored_key_wrong_size")
        XCTAssertEqual(IntakeTagAbsence.derivationFailed.rawValue, "derivation_failed")
        XCTAssertEqual(IntakeTagAbsence.sealingFailed.rawValue, "sealing_failed")
        XCTAssertEqual(IntakeTagAbsence.rejectedThisEpoch.rawValue, "rejected_this_epoch")
    }
}

/// What the client does when the server does not honour a credential it presented.
///
/// Measured on 2026-09-14 against production: 17 `unrecognised` against 8 `vouched`, with
/// `MSG_STEALTH_TOKEN_POLICY=enforce`. Every refusal turned into a failed send, because the
/// envelope that presented a credential deliberately carried no token and the one-shot recovery
/// rebuilt it with the same credential — replenishing a wallet that was never short (balance
/// 178 → 198 between two identical `missing_token` refusals).
@MainActor
final class IntakeCredentialRejectionTests: XCTestCase {

    private let peer = "ffeeddc6-14f2-4d02-a66a-caf0d8dfeda8"
    private let other = "b26a2cf8-0000-4000-8000-000000000000"
    private let service = IntakeCredentialService.shared

    /// `intakeEpoch` is one UTC day; these two are far enough apart to be different epochs
    /// whatever the machine's clock says.
    private let today = Date(timeIntervalSince1970: 1_789_392_535)
    private let tomorrow = Date(timeIntervalSince1970: 1_789_392_535 + 86_400)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "construct.intake.rejected.v1")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "construct.intake.rejected.v1")
        super.tearDown()
    }

    private func epoch(_ date: Date) -> UInt64 {
        intakeEpoch(unixSeconds: UInt64(date.timeIntervalSince1970))
    }

    /// Nothing is suppressed until something is refused — the ordinary case must stay free.
    func testAPeerIsNotSuppressedUntilTheServerRefusesOne() {
        XCTAssertFalse(service.isRejected(peer, inEpoch: epoch(today)))
    }

    /// The point of the whole change: after a refusal we stop offering that peer's credential, so
    /// the next send pays up front instead of buying the same refusal plus a retry.
    func testARefusalSuppressesThatPeerForTheRestOfTheEpoch() {
        service.noteCredentialRejected(forRecipient: peer, now: today)

        XCTAssertTrue(service.isRejected(peer, inEpoch: epoch(today)))
    }

    /// Suppression is per peer. One contact whose publishing is broken must not put every other
    /// contact back on the wallet.
    func testARefusalDoesNotSuppressAnyoneElse() {
        service.noteCredentialRejected(forRecipient: peer, now: today)

        XCTAssertFalse(service.isRejected(other, inEpoch: epoch(today)))
    }

    /// Scoped to the epoch because that is the lifetime of the thing that failed: a peer who
    /// publishes tomorrow is vouched again tomorrow, with no cache to clear.
    func testSuppressionEndsWhenTheEpochRolls() {
        service.noteCredentialRejected(forRecipient: peer, now: today)

        XCTAssertFalse(service.isRejected(peer, inEpoch: epoch(tomorrow)))
    }

    /// A peer refused yesterday and again today is still suppressed today — re-noting must move
    /// the entry forward, not leave a stale epoch behind that reads as "not suppressed".
    func testARepeatRefusalInANewEpochSuppressesAgain() {
        service.noteCredentialRejected(forRecipient: peer, now: today)
        service.noteCredentialRejected(forRecipient: peer, now: tomorrow)

        XCTAssertTrue(service.isRejected(peer, inEpoch: epoch(tomorrow)))
        XCTAssertFalse(service.isRejected(peer, inEpoch: epoch(today)), "yesterday is over")
    }

    /// Account ids differ in case between call sites; the tag derivation normalises, so the
    /// suppression must too — otherwise a refusal recorded one way is invisible looked up another.
    func testSuppressionIgnoresCase() {
        service.noteCredentialRejected(forRecipient: peer.uppercased(), now: today)

        XCTAssertTrue(service.isRejected(peer.lowercased(), inEpoch: epoch(today)))
    }

    /// Entries for epochs already past are pruned on write, so a long-lived install does not
    /// accumulate one row per contact per day forever.
    func testStaleEntriesArePrunedWhenANewOneIsRecorded() {
        service.noteCredentialRejected(forRecipient: other, now: today)
        service.noteCredentialRejected(forRecipient: peer, now: tomorrow)

        let stored = UserDefaults.standard.dictionary(forKey: "construct.intake.rejected.v1") ?? [:]
        XCTAssertNil(stored[other], "yesterday's entry is dead weight")
        XCTAssertNotNil(stored[peer])
    }
}
