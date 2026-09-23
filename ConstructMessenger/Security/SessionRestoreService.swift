//
//  SessionRestoreService.swift
//  Construct Messenger
//
//  Which sessions to bring back into the core at launch.
//

import Foundation
import CoreData

/// The order sessions are restored in, as a value.
///
/// ## Why this is a separate type
///
/// Until 2026-08-30 the answer was `chats.compactMap { $0.otherUser?.id }` and nothing else, so
/// **which sessions exist** was inferred from the chat list. The chat list is an account-space
/// list: a session keyed by a `CryptoDeviceId` has no `Chat` row and no `User` row, and none of
/// them were ever restored.
///
/// That is every session with one of our own devices. Observed on the three-device run of
/// 2026-08-30: the desktop had a live session with the phone's device `b26a2cf8` and had been
/// saving it all morning (`Session saved+verified (495B)`); after a relaunch the log read
/// `Session restore: 1 restored, 0 failed`, naming only the peer's account. Every SENDER_SYNC
/// after that was refused with `no own-device session opened … messageNumber=N > 0 — dropping`,
/// which is unrecoverable by design — only a `messageNumber == 0` copy can establish the session,
/// and the sender has no reason to send another one.
///
/// So the second device received its own account's messages until it was restarted, and never
/// again. The session was on disk the whole time.
///
/// The Keychain session namespace is the authority on which sessions exist — `PeerDeviceRegistry`
/// already says so in its header: *"Durable answers come from the session store, not from here."*
/// The chat list stays, as what it actually is: a recency order for the ones a user is likely to
/// need first.
struct SessionRestorePlan {

    /// Everything to restore, in order.
    let contactIds: [String]
    /// How many of them the chat list named. Carried here rather than recomputed by the caller so
    /// the caller holds one list and cannot iterate the other by accident — the shape of the
    /// mistake this file is fixing.
    let fromChats: Int

    var fromSessionStore: Int { contactIds.count - fromChats }

    /// Recent chats first, then every session on disk the chat list could not name.
    ///
    /// - Parameters:
    ///   - recentChatContacts: contact ids from the chat list, most recent first. Already capped.
    ///   - liveSessionContacts: contact ids of every **live** session account in the Keychain.
    static func make(recentChatContacts: [String], liveSessionContacts: [String]) -> SessionRestorePlan {
        var ordered: [String] = []
        var seen: Set<String> = []
        for contactId in recentChatContacts where !contactId.isEmpty {
            if seen.insert(contactId).inserted { ordered.append(contactId) }
        }
        let chatCount = ordered.count
        // Not capped by `limit`. The cap exists so a large chat list does not make launch slow,
        // and these are the sessions no later event re-establishes: a peer session missing from
        // the core is rebuilt by the next `messageNumber == 0` it sends, an own-device session is
        // not rebuilt by anything.
        for contactId in liveSessionContacts where !contactId.isEmpty {
            if seen.insert(contactId).inserted { ordered.append(contactId) }
        }
        return SessionRestorePlan(contactIds: ordered, fromChats: chatCount)
    }
}

/// What the Keychain session namespace holds, split by whether a per-device restore can name it.
///
/// `KeychainSessionAccounts.isSessionState` knowingly accepts three shapes: a `CryptoDeviceId`, a
/// legacy `ServerUserId`, and the pair `<ServerUserId>:<CryptoDeviceId>` written between dae2aa37
/// and the move to plain device ids. Only the first names something `restoreSession` can load — it
/// reads `session_<deviceId>` and nothing else.
///
/// A value rather than a filter inside the service, for the reason the plan above is one: the two
/// leftovers are a number someone has to decide about, and a `compactMap` that drops them silently
/// is how they would stop being visible. Before this split they were not dropped either — they
/// were handed to `restoreSession` and refused one `ERROR` at a time, on every launch.
struct LiveSessionAccounts: Equatable {
    /// Restorable, in the order the Keychain listed them.
    let deviceIds: [String]
    /// `<ServerUserId>:<CryptoDeviceId>` blobs. Reachable only by re-importing under the device
    /// half, which is a migration of crypto state and belongs in a decision, not in a restore.
    let strandedPairs: Int
    /// Pre-2026-08-26 account-keyed blobs. The core no longer keys sessions this way, so these
    /// name no ratchet at all.
    let strandedAccounts: Int

    static func classify(_ accounts: [String]) -> LiveSessionAccounts {
        var deviceIds: [String] = []
        var pairs = 0
        var legacy = 0
        for account in accounts where KeychainSessionAccounts.isLiveSession(account) {
            guard let contactId = KeychainSessionAccounts.contactId(ofAccount: account) else { continue }
            if SessionAddressing.isCryptoIdentity(contactId) {
                deviceIds.append(contactId)
            } else if KeychainSessionAccounts.perDeviceContact(ofAccount: account) != nil {
                pairs += 1
            } else {
                legacy += 1
            }
        }
        return LiveSessionAccounts(deviceIds: deviceIds, strandedPairs: pairs, strandedAccounts: legacy)
    }
}

final class SessionRestoreService {
    private let persistence: PersistenceController

    init(persistence: PersistenceController = .shared) {
        self.persistence = persistence
    }

    func restoreRecentSessions(limit: Int, restoreSession: @escaping (String) -> Bool, retryCount: Int = 0) {
        let context = persistence.container.viewContext
        guard context.persistentStoreCoordinator != nil else {
            guard retryCount < 5 else {
                Log.error("SessionRestoreService: CoreData store unavailable after \(retryCount) retries, giving up", category: "SessionRestore")
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.restoreRecentSessions(limit: limit, restoreSession: restoreSession, retryCount: retryCount + 1)
            }
            return
        }

        // Both lists are consumed inline: the plan is the only list in scope below, so there is
        // no second one to iterate by mistake.
        let plan = SessionRestorePlan.make(
            recentChatContacts: getRecentChatDeviceIds(limit: limit, context: context),
            liveSessionContacts: liveSessionDeviceIds()
        )

        // The interesting number is how many the chat list could not name — before 2026-08-30
        // that was how many were silently left out.
        if plan.fromSessionStore > 0 {
            Log.info(
                "Session restore: \(plan.fromChats) from recent chats, \(plan.fromSessionStore) more from the session store",
                category: "SessionRestore"
            )
        }

        for contactId in plan.contactIds {
            _ = restoreSession(contactId)
        }
    }

    private func liveSessionDeviceIds() -> [String] {
        let held = LiveSessionAccounts.classify(KeychainManager.shared.sessionAccounts())
        let stranded = held.strandedPairs + held.strandedAccounts
        if stranded > 0 {
            Log.info(
                "Session store holds \(held.strandedPairs) per-device-pair and \(held.strandedAccounts) "
                + "account-keyed entries that no per-device restore can name — not attempted",
                category: "SessionRestore"
            )
        }
        return held.deviceIds
    }

    /// The devices of the most recent chats, most recent chat first.
    ///
    /// Expanded here, not passed on as accounts. `Chat.otherUser?.id` is a `ServerUserId`, and
    /// everything below the seam takes a `CryptoDeviceId` — so until this expansion existed every
    /// session the chat list named was refused by `SessionAddressing.asDevice` and counted as a
    /// failure. Both testers' logs on 2026-09-23 showed it: 1 restored of 5 and 14 of 24, with an
    /// `ERROR` per refusal. The 2026-08-30 note above diagnosed the chat list as account-space and
    /// added the session store beside it; it left the account ids themselves going to a per-device
    /// call.
    ///
    /// `limit` still caps *chats*, not devices: it exists so a long chat list does not make launch
    /// slow, and a peer's second device is not a reason to restore one chat fewer.
    /// Internal, not private: `SessionRestoreSourcesTests` drives it against an in-memory store.
    /// The claim worth a test is that an account never leaves this method, and that is not
    /// visible from the outside of a service whose other half is the Keychain.
    func getRecentChatDeviceIds(limit: Int, context: NSManagedObjectContext) -> [String] {
        guard context.persistentStoreCoordinator != nil else {
            return []
        }

        let fetchRequest: NSFetchRequest<Chat> = Chat.fetchRequest()
        fetchRequest.sortDescriptors = [NSSortDescriptor(key: "lastMessageTime", ascending: false)]
        fetchRequest.fetchLimit = limit

        do {
            let chats = try context.fetch(fetchRequest)
            return chats
                .compactMap { $0.otherUser?.id }
                .flatMap { SessionAddressing.deviceIds(ofPeer: $0, in: context) }
        } catch {
            return []
        }
    }
}
