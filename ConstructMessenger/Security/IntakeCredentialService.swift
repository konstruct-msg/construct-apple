//
//  IntakeCredentialService.swift
//  Construct Messenger
//
//  The credential a sealed envelope carries instead of a Privacy Pass token.
//
//  Measured 2026-09-11 across two devices in one ordinary conversation: delivery receipts alone
//  were 36–38% of all token spend, and they are spent by the person who was *written to*. A token
//  per sealed envelope charges the same for a stranger's first contact and for the four-hundredth
//  message between two people who have been talking for a year.
//
//  The server cannot be told which envelopes to exempt — `content_type` lives inside the seal on
//  purpose — so an envelope that owes nothing says so by carrying a credential the recipient
//  issued. Design: `construct-docs/decisions/contact-traffic-is-vouched-not-purchased.md`.
//
//  Three facts hold this together and each has a place it must not drift to:
//
//  • The derivation is `construct-core`'s (`intakeTag`), including the normalisation of the
//    account id. Two clients disagreeing about case produce different tags, the envelope is
//    silently charged, and nothing reports a mismatch — this project already paid that bill on
//    2026-07-22, when recovery hashed the raw username and registration hashed the lowercased one.
//  • The tag is per *recipient*, identical for every sender holding the key. A pair-wise value
//    would be a stable pseudonymous handle for the sender inside each epoch, which is precisely
//    what sealed sender exists to destroy.
//  • Our own key is per *device*: each device of the account mints its own and publishes its own
//    tags, and the server keeps every device's tags as a set per epoch (construct-server
//    `7fd850b`). Until then it kept one value and the last device to publish revoked the others.
//

import Foundation
import SwiftProtobuf
import GRPCCore

/// Why an envelope is carrying no intake credential, and therefore paying a token.
///
/// Split out because the four causes need different reactions and used to be one silent `nil`.
/// `noKeyForPeer` is the ordinary state during rollout and for anyone who has not written to us
/// yet — it is the answer to "why did this pay", not an error. The other three are malfunctions:
/// a stored key of the wrong size is corruption, and a derivation or seal that fails means the
/// core or the server key is not where it should be.
enum IntakeTagAbsence: String {
    /// We hold no key for this account. Their key arrives the first time they write to us.
    case noKeyForPeer = "no_key_for_peer"
    /// A key is stored, but not 32 bytes. `recordPeerIntakeKey` refuses to write one, so this
    /// means the stored item was damaged rather than badly received.
    case storedKeyWrongSize = "stored_key_wrong_size"
    /// `construct-core` could not derive the tag from a key that passed the size check.
    case derivationFailed = "derivation_failed"
    /// The server's X25519 key was unavailable, so the tag could not be sealed. Sending it in the
    /// clear is not an option — any relay on the path could harvest and spend it.
    case sealingFailed = "sealing_failed"
    /// We presented a credential for this peer this epoch and the server did not honour it, so we
    /// have stopped offering it. Their published window has a hole, or their key rotated and the
    /// copy we hold is stale. Measured 2026-09-14: 17 `unrecognised` against 8 `vouched`, and
    /// every one of those 17 cost an extra round trip before this existed.
    case rejectedThisEpoch = "rejected_this_epoch"

    /// Classify what the Keychain gave us, or nil when the key is usable.
    ///
    /// Pure, and separate from the Keychain read, so the classification can be argued with in a
    /// test without one (`decisions/testing-by-pure-decision.md`).
    static func forStoredKey(_ key: Data?) -> IntakeTagAbsence? {
        guard let key else { return .noKeyForPeer }
        guard key.count == intakeKeyLength else { return .storedKeyWrongSize }
        return nil
    }

    func log(peer accountId: String) {
        let peer = accountId.prefix(8)
        switch self {
        case .noKeyForPeer:
            // Debug, not info: this fires on every send to every peer who has not written to us,
            // and at info it would drown the category it is meant to make readable.
            Log.debug("Intake: no credential for \(peer)… (\(rawValue)) — this envelope pays a token", category: "Intake")
        case .rejectedThisEpoch:
            // Info, not error: the mechanism is working as designed — it tried, was refused, and
            // stopped. Worth one line per peer per epoch because a peer that stays here is a peer
            // whose publishing is broken, and nothing else on this device would say so.
            Log.info("Intake: credential for \(peer)… was refused this epoch — paying tokens until it rolls", category: "Intake")
        case .storedKeyWrongSize, .derivationFailed, .sealingFailed:
            Log.error("Intake: cannot build a credential for \(peer)… (\(rawValue)) — this envelope pays a token", category: "Intake")
        }
    }
}

/// Length of an intake key, matching `construct-core::intake::INTAKE_KEY_LEN`. The core does not
/// export it, so this is the one place the number is written on this side.
private let intakeKeyLength = 32

/// Pure decisions about publishing and expiry, kept out of the actor so a test can argue with them
/// without a Keychain, a clock or a network (`decisions/testing-by-pure-decision.md`).
enum IntakePublishing {

    /// How many epochs ahead to publish.
    ///
    /// Not a round number for its own sake: a device that has been offline for a week must not
    /// break its *own* incoming traffic, because the tags its contacts present are the ones this
    /// device published. Seven days of silence is ordinary for a second device. The server caps
    /// one call at 14, so this stays inside a single publish.
    static let windowEpochs = 7

    /// The epochs a publish should cover, starting at `currentEpoch`.
    ///
    /// Includes the current one: a fresh install has published nothing, and its first incoming
    /// message is due today rather than tomorrow.
    static func epochsToPublish(currentEpoch: UInt64) -> [UInt64] {
        (0..<UInt64(windowEpochs)).map { currentEpoch + $0 }
    }

    /// Should we publish again, given when we last did and what epoch it is now?
    ///
    /// Re-publishing every launch would be a needless authenticated RPC on a hot path; never
    /// re-publishing would let the window drain silently until incoming traffic started paying
    /// again, with nothing visible on this device to say why. Once per epoch is the smallest
    /// cadence that keeps the window full.
    static func shouldPublish(lastPublishedEpoch: UInt64?, currentEpoch: UInt64) -> Bool {
        guard let last = lastPublishedEpoch else { return true }
        // A clock that moved backwards is not a reason to skip: `last > current` means we cannot
        // reason about the window at all, and publishing is cheap where being wrong is not.
        return last != currentEpoch
    }

    /// How often a running process asks `shouldPublish` again. A process that lives for days —
    /// Konstruct Desktop keeps running with its window closed (0.3.23+) — published once at its
    /// first stream start until 2026-10-29, and after a week its window had lapsed: every contact
    /// holding its key was "unrecognised" on the server. An hour is far below the epoch and costs
    /// nothing in between, because the RPC runs only when the epoch has changed.
    static let recheckInterval: Duration = .seconds(3600)

    /// Whether the server holds the key we published, `currentEpoch` being today. The marker goes
    /// whenever our key changes, so a marker names the current key; its tags cover `windowEpochs`
    /// from the epoch it was set in. A contact card names only a key the server holds: one it does
    /// not gets `NOT_ACCEPTED`, and the contact suspends the key for the rest of the epoch.
    static func serverHolds(lastPublishedEpoch: UInt64?, currentEpoch: UInt64) -> Bool {
        guard let last = lastPublishedEpoch, currentEpoch >= last else { return false }
        return currentEpoch - last < UInt64(windowEpochs)
    }
}

/// A block or a removal retires the key the dropped contact holds: a new generation, published so
/// the server replaces the account's tags, then a card to everyone else
/// (`decisions/intake-key-is-the-accounts-not-the-devices.md`, point 4). Only on the device where
/// the person did it — a block adopted from the server or a sibling does not come through here.
enum IntakeRotation {
    /// The new key is minted above both what we hold and what the server has, so a sibling's
    /// rotation we have not heard of yet is not undercut. A server that could not be asked counts
    /// as 0: the rotation still happens, because the old key must not stay ours.
    static func mintAbove(held: UInt32?, serverGeneration: UInt32) -> UInt32 {
        max(held ?? 0, serverGeneration)
    }

    /// The server refused our publish as stale: a sibling rotated in the same minute. Mint once
    /// above the generation it named — an address, not a retry budget. Nil when nothing is redone.
    static func reMintAbove(minted: UInt32, currentGeneration: UInt32) -> UInt32? {
        currentGeneration > minted ? currentGeneration : nil
    }

    /// Who gets the new card: everyone we hold a row for except the person dropped, the blocked and
    /// ourselves. Blocking is asked again at each send; this is only who is scheduled.
    static func sweep(_ people: [ContactRecord], dropping: String, ownAccountId: String) -> [String] {
        let dropped = dropping.lowercased(), own = ownAccountId.lowercased()
        return people
            .filter { !$0.isBlocked && $0.id.lowercased() != dropped && $0.id.lowercased() != own }
            .map(\.id)
    }

    /// Cards to contacts go out at random moments within this window, never as a batch: a burst
    /// right after a block would say on the wire that one happened.
    static let sweepWindow: TimeInterval = 3600
}

/// What the sender does with the server's verdict on a tag it presented
/// (`SendMessageResponse.intake_verdict`, construct-protos #29).
///
/// Only "not accepted" suspends the key, and only until the epoch rolls (`noteCredentialRejected`).
/// Not dropped: the usual cause is a recipient device whose window lapsed while it was off, and
/// that key works again once it publishes — a dropped key never comes back, because the recipient
/// has no reason to send its card again. "Unchecked" is the server failing to look (its tag store
/// down): acting on it would make every sender throw away working keys during an outage.
enum IntakeVerdictReaction {
    static func suspendsKey(_ verdict: Shared_Proto_Services_V1_IntakeVerdict) -> Bool {
        verdict == .notAccepted
    }
}

/// How an intake key is kept in the Keychain: the key and its generation (construct-core
/// `IntakeKeyState`), our own and each contact's.
///
/// 36 bytes — the generation big-endian, then the key. 32 bytes is an item written before
/// 2026-10-29, which had no generation: it reads as generation 0, so nothing needs migrating.
/// Anything else is damaged.
enum IntakeKeyRecord {
    static let keyLength = 32
    private static let length = 4 + keyLength

    static func encode(_ state: IntakeKeyState) -> Data {
        var g = state.generation.bigEndian
        return Data(bytes: &g, count: 4) + state.key
    }

    static func decode(_ data: Data) -> IntakeKeyState? {
        switch data.count {
        case keyLength:
            return IntakeKeyState(generation: 0, key: data)
        case length:
            let generation = data.prefix(4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return IntakeKeyState(generation: generation, key: Data(data.suffix(keyLength)))
        default:
            return nil
        }
    }
}

/// This device's own intake key: what the Keychain says, then what to do about it.
///
/// Until 2026-10-29 any nil from the Keychain minted a fresh key: an unreadable item (locked
/// device, protected data not yet available, the Mac's move to the data protection keychain on
/// 2026-10-13) replaced a key every contact already held. And every device minted its own, so a
/// contact held whichever device's key reached it last, and a key of a gone or week-dark device
/// stayed unrecognised for good. The key is the account's now, with a generation
/// (decisions/intake-key-is-the-accounts-not-the-devices.md): a device mints only when the
/// account has no live key, and otherwise waits for one from its own devices.
enum IntakeOwnKey {
    enum Decision: Equatable {
        case use(IntakeKeyState)
        /// Definitely absent, or present and damaged: what to do depends on the account (`next`).
        case absent
        /// Could not read it. It may well exist; this send pays a token and the next one asks again.
        case skip
    }

    static func decide(_ read: KeychainRead) -> Decision {
        switch read {
        case .found(let data): IntakeKeyRecord.decode(data).map { .use($0) } ?? .absent
        case .absent: .absent
        case .unreadable: .skip
        }
    }

    enum Next: Equatable {
        case use(IntakeKeyState)
        /// Our per-device key from before generations becomes the account's generation 1: the
        /// contacts that hold it stay valid. Only while the account has no generation yet.
        case promote(IntakeKeyState)
        /// No live key anywhere on the account: a new one above what the server last saw.
        case mint(above: UInt32)
        /// The account has a live key and this device does not hold it: it is due from one of
        /// our own devices. Nothing is published meanwhile, and our contacts pass on theirs.
        case wait
    }

    /// `held` is this device's key (nil if none); `serverGeneration` and `serverHasLiveTags` are
    /// `GetIntakeState` for our account. Each case is named by state — never by a key being late.
    static func next(held: IntakeKeyState?, serverGeneration: UInt32, serverHasLiveTags: Bool) -> Next {
        if let held, held.generation > 0 { return .use(held) }
        let accountIsLive = serverGeneration > 0 && serverHasLiveTags
        if let held {
            // Generation 0: the migration.
            if serverGeneration == 0 { return .promote(IntakeKeyState(generation: 1, key: held.key)) }
            return accountIsLive ? .wait : .mint(above: serverGeneration)
        }
        return accountIsLive ? .wait : .mint(above: serverGeneration)
    }
}

@MainActor
final class IntakeCredentialService {

    static let shared = IntakeCredentialService()

    private let keychain = KeychainManager.shared
    private let defaults = UserDefaults.standard

    /// **Devices** we have already handed our key to. Not secret — it is a list of who we talk
    /// to, which Core Data holds anyway — and deliberately not in the Keychain, where a per-contact
    /// item would be a second copy of the contact graph in a store that has no reason to carry one.
    ///
    /// Keyed by device since 2026-09-22; `v1` held accounts. The key is the account's, but each
    /// device of theirs seals to us on its own and needs it in hand, and an account-level mark set
    /// by the first device meant the second never got it: measured on the stand, the sibling's
    /// every envelope to us "pays a token" (`no_key_for_peer`) while the account read as served.
    /// The v1 set is dropped rather than migrated — its entries could only ever have meant the
    /// pinned device, and re-sending once per contact, lazily, is one envelope each.
    ///
    /// `v3` since 2026-09-28: what goes out is the contact card (key + account address), and a
    /// device that got only the bare key under v2 has not got our address. Every contact gets the
    /// card once, lazily, the next time the two devices talk.
    private static let sentToKey = "construct.intake.sentTo.v3"
    private static let legacySentToKeys = ["construct.intake.sentTo.v2", "construct.intake.sentTo.v1"]
    private static let lastPublishedEpochKey = "construct.intake.lastPublishedEpoch.v1"
    /// Peers whose credential the server refused, keyed by account, valued by the epoch it was
    /// refused in. Not persisted beyond UserDefaults and not secret — same reasoning as `sentToKey`.
    private static let rejectedKey = "construct.intake.rejected.v1"

    private var isPublishing = false

    /// Envelopes in flight that presented a tag, by delivery tag → recipient account. The sealed
    /// RPC sees only bytes; this is how its verdict finds the recipient it is about. Bounded: an
    /// entry whose send never answered is dead weight, and the oldest go first.
    private var presented: [Data: String] = [:]
    private var presentedOrder: [Data] = []
    private static let presentedLimit = 256

    private init() {}

    // MARK: - Our own key

    /// The account's key as this device holds it, if it has one of a generation (≥ 1). What a
    /// contact card carries; no network, no minting.
    func currentOwnKey() -> IntakeKeyState? {
        guard case .use(let state) = IntakeOwnKey.decide(keychain.readOwnIntakeKey()),
              state.generation > 0 else { return nil }
        return state
    }

    /// The account's key, settled with the server when this device holds none of a generation:
    /// promoted, minted, or nil to wait for one from our own devices. Called from publishing only,
    /// so the server is asked at most as often as we publish.
    private func resolveOwnKey() async -> IntakeKeyState? {
        let read = keychain.readOwnIntakeKey()
        let held: IntakeKeyState?
        switch IntakeOwnKey.decide(read) {
        case .skip:
            Log.error("Intake: own key unreadable (\(read.description)) — not minting; this send pays a token", category: "Intake")
            return nil
        case .use(let state) where state.generation > 0:
            return state
        case .use(let state):
            held = state
        case .absent:
            held = nil
        }
        let server: (generation: UInt32, hasLiveTags: Bool)
        do {
            server = try await MessagingServiceClient.shared.getIntakeState()
        } catch let error as RPCError where error.code == .unimplemented {
            // A server from before generations: it keeps no generation and ignores the one we
            // publish, so the account is at 0 as far as it can tell. Without this, every device
            // on an old key would stop publishing until the server caught up.
            server = (0, false)
        } catch {
            Log.info("Intake: account state unavailable (\(error.localizedDescription)) — asked again on the next publish", category: "Intake")
            return nil
        }
        switch IntakeOwnKey.next(held: held, serverGeneration: server.generation, serverHasLiveTags: server.hasLiveTags) {
        case .use(let state):
            return state
        case .promote(let state):
            return adoptAsOwn(state, why: "promoted this device's key to generation 1")
        case .mint(let above):
            guard let state = try? intakeMint(aboveGeneration: above) else { return nil }
            return adoptAsOwn(state, why: "minted generation \(state.generation) (was \(read.description), account at \(server.generation))")
        case .wait:
            Log.info("Intake: the account's key (generation \(server.generation)) is due from our own devices — not publishing", category: "Intake")
            return nil
        }
    }

    /// Makes `state` this device's key. Every copy our contacts hold of the previous one is stale,
    /// so the "sent to" list and the publish marker go: the new key is published at the next
    /// publish and each device — ours and our contacts' — gets the card on the next exchange.
    @discardableResult
    private func adoptAsOwn(_ state: IntakeKeyState, why: String) -> IntakeKeyState? {
        guard keychain.saveOwnIntakeKey(IntakeKeyRecord.encode(state)) else {
            // Returning it unsaved would decide again on the next call and hand out a key
            // nothing keeps.
            Log.error("Intake: own key could not be saved — not used", category: "Intake")
            return nil
        }
        forgetWhoHasOurKey()
        defaults.removeObject(forKey: Self.lastPublishedEpochKey)
        Log.info("Intake: \(why)", category: "Intake")
        return state
    }

    /// One of our own devices handed us the account's key (a card inside SENDER_SYNC).
    func receiveOwnKeyFromSibling(_ offered: IntakeKeyState) {
        let held: IntakeKeyState?
        switch IntakeOwnKey.decide(keychain.readOwnIntakeKey()) {
        case .use(let state): held = state
        case .absent: held = nil
        // Unreadable: adopting would overwrite a key we cannot see. The sibling sends again on
        // its next publish.
        case .skip: return
        }
        guard let offer = try? intakeOffer(held: held, offered: offered) else {
            Log.error("Intake: own device sent a malformed key — ignored", category: "Intake")
            return
        }
        guard offer == .adopt else { return }
        guard adoptAsOwn(offered, why: "took generation \(offered.generation) from our own device") != nil else { return }
        Task { await self.publishTagWindowIfNeeded() }
    }

    // MARK: - Publishing

    /// Publish a window of tags so envelopes from vouched contacts owe no token.
    ///
    /// Silent on failure by design. A publish that did not land costs tokens, not delivery: our
    /// contacts' envelopes fall back to paying, exactly as they did before this existed.
    func publishTagWindowIfNeeded(now: Date = Date()) async {
        guard let accountId = AuthSessionManager.shared.currentUserId, !accountId.isEmpty else { return }
        // A stream start and the hourly recheck can land together; one RPC is enough.
        guard !isPublishing else { return }
        isPublishing = true
        defer { isPublishing = false }

        let currentEpoch = intakeEpoch(unixSeconds: UInt64(now.timeIntervalSince1970))
        let last = defaults.object(forKey: Self.lastPublishedEpochKey) as? NSNumber
        guard IntakePublishing.shouldPublish(
            lastPublishedEpoch: last?.uint64Value, currentEpoch: currentEpoch
        ) else { return }

        guard let own = await resolveOwnKey() else { return }
        _ = await publish(own, accountId: accountId, currentEpoch: currentEpoch)
    }

    private enum PublishOutcome: Equatable {
        case stored
        /// Refused: the account is at a newer generation.
        case stale(currentGeneration: UInt32)
        case failed
    }

    private func publish(_ own: IntakeKeyState, accountId: String, currentEpoch: UInt64) async -> PublishOutcome {
        var entries: [(epoch: UInt64, tag: Data)] = []
        for epoch in IntakePublishing.epochsToPublish(currentEpoch: currentEpoch) {
            guard let tag = try? intakeTag(
                intakeKey: own.key, recipientAccountId: accountId, epoch: epoch
            ) else { continue }
            entries.append((epoch, Data(tag)))
        }
        guard !entries.isEmpty else { return .failed }

        do {
            let result = try await MessagingServiceClient.shared.publishIntakeTags(entries, generation: own.generation)
            guard result.currentGeneration <= own.generation else {
                // Refused as stale: the account moved on and the newer key is due from one of
                // our own devices. Not marked, so the next publish asks again.
                Log.info("Intake: publish of generation \(own.generation) refused — the account is at \(result.currentGeneration)", category: "Intake")
                return .stale(currentGeneration: result.currentGeneration)
            }
            // A rotation while this was in flight cleared the marker for a newer key; marking now
            // would say the server holds a key it has never seen.
            guard currentOwnKey() == own else { return .failed }
            // Recorded only on success. Recording the attempt would mean one failed publish costs
            // a whole epoch of tokens, because nothing would try again until tomorrow.
            defaults.set(NSNumber(value: currentEpoch), forKey: Self.lastPublishedEpochKey)
            Log.info("Intake: published \(result.accepted)/\(entries.count) tag(s), generation \(own.generation), for epoch \(currentEpoch)+", category: "Intake")
            await offerOwnKeyToOwnDevices(own)
            return .stored
        } catch {
            Log.info("Intake: tag publish failed (\(error.localizedDescription)) — contacts keep paying tokens until it lands", category: "Intake")
            return .failed
        }
    }

    /// The key a contact card may name: ours, and held by the server. Nil while a new key is not
    /// published yet — the contact stays owed and gets the card with the first message after the
    /// publish lands.
    func publishedOwnKey(now: Date = Date()) -> IntakeKeyState? {
        let last = defaults.object(forKey: Self.lastPublishedEpochKey) as? NSNumber
        let epoch = intakeEpoch(unixSeconds: UInt64(now.timeIntervalSince1970))
        guard IntakePublishing.serverHolds(lastPublishedEpoch: last?.uint64Value, currentEpoch: epoch) else { return nil }
        return currentOwnKey()
    }

    // MARK: - Rotation

    /// The person blocked or removed `accountId` on this device: retire the key they hold.
    func rotate(dropping accountId: String) async {
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        // An unreadable key is replaced all the same: what we cannot read, we cannot keep handing out.
        let held: UInt32?
        if case .use(let state) = IntakeOwnKey.decide(keychain.readOwnIntakeKey()) { held = state.generation } else { held = nil }
        let serverGeneration = (try? await MessagingServiceClient.shared.getIntakeState().generation) ?? 0

        let epoch = intakeEpoch(unixSeconds: UInt64(Date().timeIntervalSince1970))
        var above = IntakeRotation.mintAbove(held: held, serverGeneration: serverGeneration)
        var outcome = PublishOutcome.failed
        for _ in 0..<2 {
            guard let minted = try? intakeMint(aboveGeneration: above),
                  adoptAsOwn(minted, why: "rotated to generation \(minted.generation) — a contact was dropped") != nil
            else { return }
            outcome = await publish(minted, accountId: myId, currentEpoch: epoch)
            guard case .stale(let current) = outcome,
                  let next = IntakeRotation.reMintAbove(minted: minted.generation, currentGeneration: current)
            else { break }
            above = next
        }
        // Not stored: no sweep. The contacts stay owed and get the card lazily, once a publish lands.
        guard outcome == .stored else { return }

        let people = (try? LocalRepositories.contacts.everyContact(except: myId)) ?? []
        let recipients = IntakeRotation.sweep(people, dropping: accountId, ownAccountId: myId)
        Log.info("Intake: new key goes to \(recipients.count) contact(s) within the hour", category: "Intake")
        for contactId in recipients {
            let delay = Double.random(in: 0..<IntakeRotation.sweepWindow)
            Task {
                try? await Task.sleep(for: .seconds(delay))
                await OutboundSessionService.shared.sendContactCard(to: contactId)
            }
        }
    }

    // MARK: - Peer keys

    /// A peer handed us the key their account accepts. Kept only if its generation is above the
    /// one we hold (`intakeOffer`): a late card, or an old build's per-device key, does not
    /// replace the account's current one.
    func recordPeerIntakeKey(_ offered: IntakeKeyState, from accountId: String) {
        let held = keychain.loadPeerIntakeKey(forAccount: accountId).flatMap(IntakeKeyRecord.decode)
        guard let offer = try? intakeOffer(held: held, offered: offered) else {
            Log.error("Intake: peer \(accountId.prefix(8))… sent a \(offered.key.count)-byte key — ignored", category: "Intake")
            return
        }
        guard offer == .adopt else {
            Log.debug("Intake: kept generation \(held?.generation ?? 0) from \(accountId.prefix(8))… over \(offered.generation)", category: "Intake")
            return
        }
        keychain.savePeerIntakeKey(IntakeKeyRecord.encode(offered), forAccount: accountId)
        Log.info("Intake: stored intake key generation \(offered.generation) from \(accountId.prefix(8))…", category: "Intake")
    }

    /// Hand the account's key to our own devices that do not have it yet — a device linked since,
    /// or every one of them after a change. In SENDER_SYNC, like read markers.
    private func offerOwnKeyToOwnDevices(_ own: IntakeKeyState) async {
        guard let myUserId = AuthSessionManager.shared.currentUserId, !myUserId.isEmpty,
              let myDeviceId = AuthSessionManager.shared.currentDeviceId, !myDeviceId.isEmpty,
              let card = try? ContactCardPayload(intakeKey: own.key, accountAddress: nil,
                                                 intakeGeneration: own.generation).encoded() else { return }
        let sent = await MultiDeviceSendCoordinator.shared.sendOwnContactCard(
            card, skipping: sentTo(), senderUserId: myUserId, senderDeviceId: myDeviceId
        )
        if !sent.isEmpty {
            markOurKeySent(to: sent)
            Log.info("Intake: generation \(own.generation) handed to \(sent.count) own device(s)", category: "Intake")
        }
    }

    /// The sealed tag to attach to an envelope for `accountId`, or nil when we hold no key for
    /// them, cannot derive, or cannot seal.
    ///
    /// Nil is not a failure: the envelope pays with a token, which is what every envelope did
    /// before this existed. But it is the reason it paid, and until 2026-09-14 every one of the
    /// four ways to get here returned the same silent nil. The device log then said
    /// "sealed send WITH token" and nothing else, so "why did this envelope pay?" had no answer
    /// on the device that paid — which is exactly the question asked of the 09-13 stretch where
    /// the server counted 8 envelopes as `absent` and nobody could say which cause it was.
    func sealedTag(forRecipient accountId: String, now: Date = Date()) async -> Data? {
        let epoch = intakeEpoch(unixSeconds: UInt64(now.timeIntervalSince1970))
        // Asked before the Keychain read: a credential the server refused this epoch is not worth
        // deriving, and offering it again would buy the same rejection plus a retry on every
        // single send to this peer.
        if isRejected(accountId, inEpoch: epoch) {
            IntakeTagAbsence.rejectedThisEpoch.log(peer: accountId)
            return nil
        }

        let stored = keychain.loadPeerIntakeKey(forAccount: accountId).map { IntakeKeyRecord.decode($0)?.key ?? $0 }
        if let reason = IntakeTagAbsence.forStoredKey(stored) {
            reason.log(peer: accountId)
            return nil
        }
        // `forStoredKey` returning nil is exactly the statement that this is a usable 32-byte key.
        guard let key = stored else { return nil }

        guard let tag = try? intakeTag(
            intakeKey: key, recipientAccountId: accountId, epoch: epoch
        ) else {
            IntakeTagAbsence.derivationFailed.log(peer: accountId)
            return nil
        }
        // Sealed to the server's X25519 key with the same box `token_bytes` uses. SealedInner is a
        // plaintext proto the relay parses: a tag in the clear is one any relay can harvest and
        // then spend on this recipient until the epoch rolls.
        guard let sealed = await ServerKeyManager.shared.sealTokenBytes(Data(tag)) else {
            IntakeTagAbsence.sealingFailed.log(peer: accountId)
            return nil
        }
        return sealed
    }

    // MARK: - When the server does not honour a credential

    /// The server refused an envelope that carried this peer's credential — stop offering it until
    /// the epoch rolls.
    ///
    /// A Privacy Pass rejection on an envelope that paid with a credential is proof the credential
    /// was not accepted: had it been, the server would not have looked at tokens at all. The cause
    /// is on the recipient's side — a hole in their published window, or a rotation that left our
    /// copy of their key stale — and neither is something this device can fix or should keep
    /// re-testing once per message.
    ///
    /// Scoped to the epoch because that is the lifetime of the thing that failed. A peer who
    /// publishes tomorrow is vouched again tomorrow, with no cache to clear and nothing to reset.
    func noteCredentialRejected(forRecipient accountId: String, now: Date = Date()) {
        let epoch = intakeEpoch(unixSeconds: UInt64(now.timeIntervalSince1970))
        var rejected = rejectedEpochs()
        // Prune while we are here: entries for past epochs are dead weight, and this is the only
        // moment the map is written.
        rejected = rejected.filter { $0.value >= epoch }
        rejected[normalise(accountId)] = epoch
        defaults.set(rejected, forKey: Self.rejectedKey)
    }

    /// An envelope for `accountId` carrying our tag for them is about to go out.
    func notePresented(deliveryTag: Data, forRecipient accountId: String) {
        guard !deliveryTag.isEmpty else { return }
        presented[deliveryTag] = accountId
        presentedOrder.append(deliveryTag)
        if presentedOrder.count > Self.presentedLimit {
            presented.removeValue(forKey: presentedOrder.removeFirst())
        }
    }

    /// The server answered a sealed send. `sealedInner` is the envelope that was sent; its
    /// delivery tag says which recipient the verdict is about.
    func noteVerdict(_ verdict: Shared_Proto_Services_V1_IntakeVerdict, sealedInner: Data) {
        guard let inner = try? Shared_Proto_Core_V1_SealedInner(serializedBytes: sealedInner),
              let accountId = presented.removeValue(forKey: inner.deliveryTag) else { return }
        presentedOrder.removeAll { $0 == inner.deliveryTag }
        guard IntakeVerdictReaction.suspendsKey(verdict) else { return }
        noteCredentialRejected(forRecipient: accountId)
        Log.info("Intake: server did not accept our tag for \(accountId.prefix(8))… — paying tokens until the epoch rolls", category: "Intake")
    }

    /// Is this peer's credential suppressed for `epoch`?
    func isRejected(_ accountId: String, inEpoch epoch: UInt64) -> Bool {
        rejectedEpochs()[normalise(accountId)] == epoch
    }

    private func rejectedEpochs() -> [String: UInt64] {
        // Stored through UserDefaults, which keeps numbers as NSNumber — read back as a plist
        // dictionary rather than assuming the Swift type survives the round trip.
        guard let raw = defaults.dictionary(forKey: Self.rejectedKey) else { return [:] }
        return raw.compactMapValues { ($0 as? NSNumber)?.uint64Value }
    }

    // MARK: - Lazy distribution

    /// Which of `devices` still need our key.
    ///
    /// Grandfathering is lazy by decision: sweeping the contact graph on upgrade would mean a
    /// hundred sealed control envelopes at once, each of which must itself be paid for, and would
    /// pay that for contacts the user may never write to again. The graph migrates in the order it
    /// is actually used. The caller names the devices — the ones it holds a session with — because
    /// this service does not know a peer's device set and must not grow a copy of it.
    func devicesNeedingOurKey(among devices: [String]) -> [String] {
        let sent = sentTo()
        return devices.filter { !sent.contains(normalise($0)) }
    }

    func markOurKeySent(to devices: [String]) {
        var set = sentTo()
        for device in devices { set.insert(normalise(device)) }
        defaults.set(Array(set), forKey: Self.sentToKey)
    }

    /// We rotated, so every contact's copy is stale and must be re-sent lazily.
    ///
    /// Rotation *is* revocation — there is no server-side deny entry for one contact, by design.
    func forgetWhoHasOurKey() {
        defaults.removeObject(forKey: Self.sentToKey)
        Self.legacySentToKeys.forEach(defaults.removeObject(forKey:))
    }

    private func sentTo() -> Set<String> {
        Self.legacySentToKeys.forEach(defaults.removeObject(forKey:))
        return Set(defaults.stringArray(forKey: Self.sentToKey) ?? [])
    }

    private func normalise(_ accountId: String) -> String {
        accountId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
