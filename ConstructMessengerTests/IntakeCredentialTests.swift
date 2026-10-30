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

@MainActor
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
@MainActor
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

    override func setUp() async throws {
        try await super.setUp()
        UserDefaults.standard.removeObject(forKey: "construct.intake.rejected.v1")
    }

    override func tearDown() async throws {
        UserDefaults.standard.removeObject(forKey: "construct.intake.rejected.v1")
        try await super.tearDown()
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

    /// A peer rotated: the tag from their old key was refused and we suspended it. Their card with
    /// the next generation arrives — the suspension was about the key we no longer hold.
    func testAdoptingANewerKeyLiftsTheSuspension() {
        defer { KeychainManager.shared.deletePeerIntakeKey(forAccount: peer) }
        service.recordPeerIntakeKey(IntakeKeyState(generation: 1, key: Data(repeating: 1, count: 32)), from: peer)
        service.noteCredentialRejected(forRecipient: peer)
        service.noteCredentialRejected(forRecipient: other)

        service.recordPeerIntakeKey(IntakeKeyState(generation: 2, key: Data(repeating: 2, count: 32)), from: peer)

        let now = epoch(Date())
        XCTAssertFalse(service.isRejected(peer, inEpoch: now))
        XCTAssertTrue(service.isRejected(other, inEpoch: now), "only the account whose key changed")
    }

    /// A card we keep the old key over — the same generation again, or an older one — says nothing
    /// about the key the server refused.
    func testAKeptKeyDoesNotLiftTheSuspension() {
        defer { KeychainManager.shared.deletePeerIntakeKey(forAccount: peer) }
        service.recordPeerIntakeKey(IntakeKeyState(generation: 2, key: Data(repeating: 1, count: 32)), from: peer)
        service.noteCredentialRejected(forRecipient: peer)

        service.recordPeerIntakeKey(IntakeKeyState(generation: 2, key: Data(repeating: 1, count: 32)), from: peer)
        service.recordPeerIntakeKey(IntakeKeyState(generation: 1, key: Data(repeating: 3, count: 32)), from: peer)

        XCTAssertTrue(service.isRejected(peer, inEpoch: epoch(Date())))
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

/// Who holds our intake key — devices, not accounts.
///
/// An account-level mark set by the first device meant the second never got the key: on the
/// stand the sibling's every envelope to us paid a token (`no_key_for_peer`) while the account
/// read as served. The service does not know a peer's device set; the caller names the devices
/// it holds sessions with, and the answer is which of *those* still lack the key.
@MainActor
final class IntakeKeyDistributionTests: XCTestCase {

    private let service = IntakeCredentialService.shared
    private let a = "c6bfaaefcdd4e6ca0000000000000001"
    private let b = "b814c8ab96bc44960000000000000002"

    override func setUp() async throws {
        try await super.setUp()
        service.forgetWhoHasOurKey()
    }

    override func tearDown() async throws {
        service.forgetWhoHasOurKey()
        try await super.tearDown()
    }

    /// Mutation: mark by account again — `b` would read as served the moment `a` is, and this
    /// reddens.
    func testMarkingOneDeviceLeavesTheSiblingOwed() {
        XCTAssertEqual(service.devicesNeedingOurKey(among: [a, b]), [a, b])
        service.markOurKeySent(to: [a])
        XCTAssertEqual(service.devicesNeedingOurKey(among: [a, b]), [b])
        service.markOurKeySent(to: [b])
        XCTAssertEqual(service.devicesNeedingOurKey(among: [a, b]), [])
    }

    /// Rotation is revocation: every device is owed the new key.
    func testForgettingOwesEveryDeviceAgain() {
        service.markOurKeySent(to: [a, b])
        service.forgetWhoHasOurKey()
        XCTAssertEqual(service.devicesNeedingOurKey(among: [a, b]), [a, b])
    }

    /// The v1 set held accounts and is dropped, not read: an entry there could only have meant
    /// the pinned device, and reading it as "every device" is the defect this replaces.
    func testTheAccountKeyedSetIsNotConsulted() {
        UserDefaults.standard.set([a], forKey: "construct.intake.sentTo.v1")
        XCTAssertEqual(service.devicesNeedingOurKey(among: [a]), [a])
        XCTAssertNil(UserDefaults.standard.stringArray(forKey: "construct.intake.sentTo.v1"), "dropped on first read")
    }
}

/// The Keychain item: 32 bytes is a key from before generations (generation 0), 36 bytes the
/// generation and the key. A wrong reading would either re-mint over a key contacts hold or keep
/// presenting a key at the wrong generation.
final class IntakeKeyRecordTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    func testRoundTrip() {
        let state = IntakeKeyState(generation: 300, key: key)
        XCTAssertEqual(IntakeKeyRecord.decode(IntakeKeyRecord.encode(state)), state)
    }

    /// Mutation: decode the 32-byte case as nil — this reddens.
    func testAnItemFromBeforeGenerationsIsGenerationZero() {
        XCTAssertEqual(IntakeKeyRecord.decode(key), IntakeKeyState(generation: 0, key: key))
    }

    /// Big-endian, so 300 is not read back as 11265.
    func testTheGenerationIsBigEndian() {
        XCTAssertEqual(IntakeKeyRecord.encode(IntakeKeyState(generation: 300, key: key)).prefix(4),
                       Data([0, 0, 1, 44]))
    }

    func testAnyOtherLengthIsDamaged() {
        XCTAssertNil(IntakeKeyRecord.decode(Data(repeating: 7, count: 16)))
        XCTAssertNil(IntakeKeyRecord.decode(Data(repeating: 7, count: 37)))
    }
}

/// What the Keychain said. Minting is never decided here any more — only whether the key is
/// there, missing, or unreadable.
final class IntakeOwnKeyTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    func testAStoredKeyIsUsed() {
        let state = IntakeKeyState(generation: 2, key: key)
        XCTAssertEqual(IntakeOwnKey.decide(.found(IntakeKeyRecord.encode(state))), .use(state))
    }

    func testNoKeyIsAbsent() {
        XCTAssertEqual(IntakeOwnKey.decide(.absent), .absent)
    }

    /// Locked device, protected data not available, the Mac's keychain move: the key may exist.
    /// Mutation: `.unreadable: .absent` — this reddens.
    func testAnUnreadableKeychainIsSkipped() {
        XCTAssertEqual(IntakeOwnKey.decide(.unreadable(errSecInteractionNotAllowed)), .skip)
    }

    func testADamagedItemIsAbsent() {
        XCTAssertEqual(IntakeOwnKey.decide(.found(Data(repeating: 7, count: 16))), .absent)
    }
}

/// When a device uses, promotes, mints or waits (decisions/intake-key-is-the-accounts-not-the-
/// devices.md, plan, «Когда устройство создаёт поколение»). A device that mints while the
/// account has a live key splits the account's contacts across two keys again.
final class IntakeOwnKeyNextTests: XCTestCase {
    private let key = Data(repeating: 7, count: 32)

    func testAKeyOfAGenerationIsUsedWithoutAsking() {
        let held = IntakeKeyState(generation: 3, key: key)
        XCTAssertEqual(IntakeOwnKey.next(held: held, serverGeneration: 9, serverHasLiveTags: true), .use(held))
    }

    /// The migration: the first updated device keeps its key and calls it generation 1.
    /// Mutation: `.promote` → `.mint(above: 0)` — this reddens.
    func testAPerDeviceKeyIsPromotedWhileTheAccountHasNoGeneration() {
        let held = IntakeKeyState(generation: 0, key: key)
        XCTAssertEqual(IntakeOwnKey.next(held: held, serverGeneration: 0, serverHasLiveTags: true),
                       .promote(IntakeKeyState(generation: 1, key: key)))
    }

    /// Another device already moved the account on: ours is stale, theirs is on its way.
    func testAPerDeviceKeyWaitsOnceTheAccountHasALiveGeneration() {
        let held = IntakeKeyState(generation: 0, key: key)
        XCTAssertEqual(IntakeOwnKey.next(held: held, serverGeneration: 2, serverHasLiveTags: true), .wait)
    }

    /// A new device linked to a live account must not mint.
    /// Mutation: no key → always `.mint` — this reddens.
    func testNoKeyWaitsWhileTheAccountIsLive() {
        XCTAssertEqual(IntakeOwnKey.next(held: nil, serverGeneration: 4, serverHasLiveTags: true), .wait)
    }

    /// Restored onto a new device with the old ones gone: nothing is published any more.
    /// Mutation: `serverGeneration > 0 && serverHasLiveTags` → `serverGeneration > 0` — this reddens.
    func testNoKeyMintsAboveTheServerWhenNothingIsLive() {
        XCTAssertEqual(IntakeOwnKey.next(held: nil, serverGeneration: 4, serverHasLiveTags: false), .mint(above: 4))
    }

    /// The account's first device, or one migrating with siblings still on old builds.
    func testNoKeyOnAnAccountWithoutAGenerationMintsTheFirst() {
        XCTAssertEqual(IntakeOwnKey.next(held: nil, serverGeneration: 0, serverHasLiveTags: false), .mint(above: 0))
        XCTAssertEqual(IntakeOwnKey.next(held: nil, serverGeneration: 0, serverHasLiveTags: true), .mint(above: 0))
    }
}

/// The server's verdict on a presented tag. Only "not accepted" may change what the sender does;
/// "unchecked" is the server failing to look, and acting on it would make every sender drop a
/// working key during an outage.
final class IntakeVerdictReactionTests: XCTestCase {

    /// Mutation: `verdict != .accepted` — this reddens on `.unchecked`.
    func testOnlyNotAcceptedSuspendsTheKey() {
        XCTAssertTrue(IntakeVerdictReaction.suspendsKey(.notAccepted))
        XCTAssertFalse(IntakeVerdictReaction.suspendsKey(.unchecked))
        XCTAssertFalse(IntakeVerdictReaction.suspendsKey(.accepted))
        XCTAssertFalse(IntakeVerdictReaction.suspendsKey(.none))
        // An older server leaves the field unset.
        XCTAssertFalse(IntakeVerdictReaction.suspendsKey(.unspecified))
    }
}

/// A card names only a key the server holds. The marker goes whenever our key changes, so it
/// names the current key; its tags last `windowEpochs`.
final class IntakeServerHoldsTests: XCTestCase {

    /// Mutation: `guard let last = lastPublishedEpoch` → `?? 0` — a never-published key reads as held.
    func testNothingPublishedIsNotHeld() {
        // An epoch inside a window counted from 0, so reading nil as epoch 0 would say "held".
        XCTAssertFalse(IntakePublishing.serverHolds(lastPublishedEpoch: nil, currentEpoch: 3))
        XCTAssertFalse(IntakePublishing.serverHolds(lastPublishedEpoch: nil, currentEpoch: 100))
    }

    /// Mutation: `<` → `<=` — the day after the window reads as held.
    func testHeldForTheWindowAndNotAfter() {
        XCTAssertTrue(IntakePublishing.serverHolds(lastPublishedEpoch: 100, currentEpoch: 100))
        XCTAssertTrue(IntakePublishing.serverHolds(lastPublishedEpoch: 100, currentEpoch: 106))
        XCTAssertFalse(IntakePublishing.serverHolds(lastPublishedEpoch: 100, currentEpoch: 107))
    }

    /// A clock that went backwards cannot reason about the window.
    func testAMarkerFromTheFutureIsNotHeld() {
        XCTAssertFalse(IntakePublishing.serverHolds(lastPublishedEpoch: 101, currentEpoch: 100))
    }
}

/// Point 4: a block or a removal retires the key the dropped contact holds.
final class IntakeRotationTests: XCTestCase {

    /// A sibling rotated and we have not heard: the new key goes above the server's.
    /// Mutation: `max(held ?? 0, serverGeneration)` → `held ?? 0` — this reddens.
    func testMintsAboveTheServerWhenItIsAhead() {
        XCTAssertEqual(IntakeRotation.mintAbove(held: 2, serverGeneration: 5), 5)
    }

    /// Mutation: → `serverGeneration` — this reddens.
    func testMintsAboveWhatWeHoldWhenTheServerIsBehindOrUnreachable() {
        XCTAssertEqual(IntakeRotation.mintAbove(held: 3, serverGeneration: 0), 3)
        XCTAssertEqual(IntakeRotation.mintAbove(held: nil, serverGeneration: 0), 0)
    }

    /// Mutation: `>` → `>=` — an equal generation (the server merges it) would re-mint.
    func testReMintsOnceAboveANewerAccount() {
        XCTAssertEqual(IntakeRotation.reMintAbove(minted: 4, currentGeneration: 6), 6)
        XCTAssertNil(IntakeRotation.reMintAbove(minted: 4, currentGeneration: 4))
        XCTAssertNil(IntakeRotation.reMintAbove(minted: 4, currentGeneration: 3))
    }

    /// Mutations, each reddens: drop `!$0.isBlocked`; drop the dropped-id check; drop the own-id check;
    /// compare without `lowercased()`.
    func testTheSweepSkipsTheDroppedTheBlockedAndOurselves() {
        let people = [record("a"), record("B-DROPPED"), record("c", blocked: true), record("me"), record("d")]
        XCTAssertEqual(IntakeRotation.sweep(people, dropping: "b-dropped", ownAccountId: "ME"), ["a", "d"])
    }

    private func record(_ id: String, blocked: Bool = false) -> ContactRecord {
        ContactRecord(
            id: id, username: id, displayName: id, localAlias: nil, avatar: nil,
            knownIdentityKey: nil, accountAddress: nil, isContact: true, isBlocked: blocked,
            isSharingWithMe: false, amISharingWith: false, sharedWithMeAt: nil,
            addedAt: nil, ktStatus: .unverified, securityNotice: .none,
            profileEditedAtMs: 0, pendingAvatarRef: nil, pendingAvatarSince: nil
        )
    }
}
