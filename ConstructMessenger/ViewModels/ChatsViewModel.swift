//
//  ChatsViewModel.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 13.12.2025.
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif

@Observable
@MainActor
class ChatsViewModel {
    private static let sharedStreamManager = MessageStreamManager.shared
    private static let sharedStreamLifecycle: StreamLifecycleCoordinator = {
        let controller = SessionLifecycleController.shared
        let lifecycle = StreamLifecycleCoordinator(
            streamManager: MessageStreamManager.shared,
            sessionCoordinator: controller.coordinator
        )
        controller.configure(streamManager: MessageStreamManager.shared)
        controller.onEphemeralSubscriptionNeeded = { [weak lifecycle] userId in
            lifecycle?.addEphemeralSubscription(for: userId)
        }
        if !PreviewDetector.isRunningInPreview {
            lifecycle.start()
        }
        return lifecycle
    }()
    private static let sharedContactAcceptedObserver: NSObjectProtocol? = {
        guard !PreviewDetector.isRunningInPreview else { return nil }
        return NotificationCenter.default.addObserver(
            forName: .contactRequestAccepted, object: nil, queue: nil
        ) { _ in
            Task { @MainActor in
                ChatsViewModel.sharedStreamLifecycle.reconnectIfSubscriptionsChanged()
            }
        }
    }()

    // MARK: - UI state

    var chatToOpen: String?
    var selectedTab: Int = 0
    var showNewChat: Bool = false
    var sidebarSearchFocused: Bool = false
    var totalUnreadCount: Int = 0
    var pendingDroppedImage: PlatformImage? = nil
    var pendingDroppedFileURL: URL? = nil

    // MARK: - Core dependencies

    private let streamManager: MessageStreamManager
    private let chatManagementService = ChatManagementService()
    private let streamLifecycle: StreamLifecycleCoordinator

    // MARK: - Setup state

    private var viewContext: NSManagedObjectContext?
    private var didPerformFirstContextSetup = false

    // Persistent lastMessageId (survives app restart)
    private var lastMessageId: String? {
        didSet {
            if let id = lastMessageId {
                UserDefaults.standard.set(id, forKey: "construct.lastMessageId")
                Log.debug("Saved lastMessageId: \(id)", category: "ChatsViewModel")
            } else {
                UserDefaults.standard.removeObject(forKey: "construct.lastMessageId")
            }
        }
    }

    // MARK: - Init

    init() {
        self.streamManager = Self.sharedStreamManager
        self.streamLifecycle = Self.sharedStreamLifecycle
        _ = Self.sharedContactAcceptedObserver

        self.lastMessageId = UserDefaults.standard.string(forKey: "construct.lastMessageId")
        if let restored = lastMessageId {
            Log.info("Restored lastMessageId from UserDefaults: \(restored)", category: "ChatsViewModel")
        }
    }

    // MARK: - Context

    func setContext(_ context: NSManagedObjectContext) {
        if let existing = viewContext, existing === context { return }
        self.viewContext = context
        SessionLifecycleController.shared.setContext(context)
        chatManagementService.setContext(context)
        streamLifecycle.setContext(context)
        if !didPerformFirstContextSetup && streamManager.subscriptionUserIds.isEmpty {
            didPerformFirstContextSetup = true
            streamLifecycle.forceReconnect()
        }
        SessionHealingService.shared.restoreQueueState()
        PersistentACKStore.shared.pruneExpired(in: context)
        SessionHealingService.shared.pruneExpired(in: context)
    }

    // MARK: - Stream (pass-throughs for external callers)

    func startMessageStream() {
        streamLifecycle.startMessageStream()
    }

    func stopMessageStream() {
        streamLifecycle.stopMessageStream()
    }

    // MARK: - Chat operations

    func startChat(
        with user: PublicUserInfo,
        identityPublicKey: Data? = nil,
        origin: SessionReducer.ChatStartOrigin = .existingContact
    ) -> Chat? {
        let chat = chatManagementService.startChat(with: user, identityPublicKey: identityPublicKey)
        streamLifecycle.reconnectIfSubscriptionsChanged()

        if SessionReducer.chatStartRetiresExistingSession(origin: origin) {
            // Redeeming an invite means the two sides are establishing a session now, so anything
            // left from before is retired first — including a Keychain entry the core has not
            // loaded, which `hasSession` cannot see and `archiveSession` now can.
            //
            // This replaces a `clearArchivedSessions` that did the opposite of what was needed:
            // it removed the archives, which are the fallback for decrypting anything still in
            // flight, and kept the live session, which is the one thing guaranteed to be wrong
            // after the peer has re-paired. See `chatStartRetiresExistingSession`.
            if CryptoManager.shared.hasStoredSessionStateForAnyDevice(ofPeer: user.id) {
                // Every device of theirs, not the pinned one. A re-pairing that retired one
                // ratchet and left the rest would re-establish beside sessions the peer has
                // already thrown away.
                let retired = CryptoManager.shared.archiveAllSessions(ofPeer: user.id, reason: .manualReset)
                Log.info(
                    "Invite redeem: retired \(retired) session(s) with \(user.id.prefix(8))… before re-establishing",
                    category: "SessionInit"
                )
            }
            SessionLifecycleController.shared.prewarmSessions(for: [user.id])
        } else if !CryptoManager.shared.hasSession(for: user.id) {
            CryptoManager.shared.clearArchivedSessions(for: user.id)
            SessionLifecycleController.shared.prewarmSessions(for: [user.id])
        }
        return chat
    }

    func sendEndSession(to userId: String, reason: String = "manual_reset") async throws {
        try await SessionLifecycleController.shared.sendEndSession(to: userId, reason: reason)
    }

    func sendEndSessionToAllContacts(reason: String = "logout") async {
        await SessionLifecycleController.shared.sendEndSessionToAllContacts(reason: reason)
    }

    func deleteChat(chat: Chat) {
        chatManagementService.deleteChat(chat)
    }

    /// Remove a contact from this device, and tell them the session is over.
    ///
    /// **Why it announces at all.** Deleting a contact used to be silent, and silence made the
    /// state unrecoverable: `MessageRouter` resurrects a pruned contact when a **handshake**
    /// arrives, but a peer holding a healthy session never sends one — it sends mid-ratchet
    /// traffic, which is dropped. 2026-09-04 16:18:15 a contact was pruned; the peer sent msgNum
    /// 1 through 5 over the next fifty-one seconds, every one dropped, every one reading *sent*
    /// on their screen, and the conversation came back only by scanning the QR code again. The
    /// teardown makes the door that already exists reachable: their session dies, they
    /// re-initialise, the handshake arrives, the contact returns.
    ///
    /// **Why that is not a hole.** Refusing someone is the block button's job, and the server
    /// enforces it before delivery. This control answers "what do I keep", not "what may they
    /// do", and a client-side refusal was never the second thing anyway — it dropped the message
    /// after paying for it.
    ///
    /// **Why the order differs from a chat delete.** There the local delete runs first, because
    /// everything after it can die. Here it cannot: the teardown resolves the peer's devices from
    /// the very rows this prune destroys, so announcing afterwards would announce to nobody. The
    /// window that buys is honest — dying inside it leaves the contact in place, which is a state
    /// the person can see and repeat, unlike a row that has already left the list.
    func pruneContact(userId: String) async {
        Log.info("Contact prune requested for \(userId.prefix(8))…", category: "ChatsViewModel")

        // Every device of this contact, resolved **before** anything local is destroyed.
        //
        // `deviceIds(ofPeer:)` prefers `PeerDevice` rows — which survive the prune, having no
        // relationship to `User` — but falls back to `contactId(forPeer:)`, and that reads
        // `User.knownIdentityKey`, which does not. So for a contact we hold no `PeerDevice` row
        // for, which is every peer we have only ever received from, resolving after the prune
        // returns nothing. `archiveSessions(ofPeer:)` ran in exactly that position and archived
        // nothing for those contacts.
        let context = PersistenceController.shared.container.viewContext
        let peerDevices = SessionAddressing.deviceIds(ofPeer: userId, in: context)

        // Same gate as a chat delete, for the same reason: delivery does not name the sending
        // device, so a secondary device announcing a teardown has it applied to whichever device
        // the peer's addressing resolves to — possibly our primary. §D landed 2026-09-05 and our
        // END_SESSION now names the device that sent it, so the hazard is gone against a peer that
        // reads the tag; the gate stays for peers on older builds, which still attribute an
        // inbound teardown to their pinned device. On a multi-device account the prune stays
        // silent, and the peer keeps a session we will not read; that cost is stated, not hidden.
        let myUserId = AuthSessionManager.shared.currentUserId ?? ""
        var devices = MultiDeviceSendCoordinator.shared.knownOwnDevices(myUserId: myUserId)
        if devices.isEmpty {
            devices = await MultiDeviceSendCoordinator.shared.refreshOwnDevices(myUserId: myUserId)
        }
        if Self.mayAnnounceTeardown(ownDeviceCount: devices.isEmpty ? nil : devices.count) {
            do {
                try await SessionLifecycleController.shared.sendEndSession(to: userId, reason: "contact_pruned")
            } catch {
                Log.error("END_SESSION failed before prune (continuing): \(error)", category: "ChatsViewModel")
            }
        } else {
            Log.info(
                "Prune of \(userId.prefix(8))…: not announcing teardown — \(devices.isEmpty ? "device set unknown" : "\(devices.count) device(s) on this account") and delivery cannot name which one asked",
                category: "ChatsViewModel"
            )
        }

        chatManagementService.pruneContactLocally(userId: userId)

        // Forget rather than archive. An archive keeps the ratchet for a late message, which is
        // the right answer for a session that ended; this contact is gone, and the leftovers are
        // what steer the next add if they ever come back. `forgetContactState` (core 0.16.0) drops
        // the archive, the prekey counter, the heal record, the PQ contribution, the init lock,
        // the cooldown, the pending END_SESSION and the queued carriers — none of which
        // `remove_session` touched, and none of which was reachable from here before.
        for device in peerDevices {
            CryptoManager.shared.forgetContactState(for: device)
        }
        // The core's heal record is not the one this app consults. `SessionHealingService` holds
        // its **own** `RustHealingQueue` instance — a different object from the one inside
        // `OrchestratorCore.lifecycle` — and it is that one which answers `canHeal` and counts
        // attempts. Forgetting in the core leaves it untouched, so the prune has to clear both.
        // Collapsing the two is step 4 of decisions/session-is-one-state-machine.
        SessionHealingService.shared.clearQueue(for: userId, in: context)

        Log.info(
            "Synapse pruned: \(userId.prefix(8))… — forgot \(peerDevices.count) device session(s)",
            category: "ChatsViewModel"
        )
        streamLifecycle.reconnectIfSubscriptionsChanged()
    }

    func openOrCreateChat(with user: User) {
        selectedTab = 0
        guard let context = viewContext else { return }
        // Always go through the shared 1:1 finder — do not trust `user.chats` alone
        // (relationship can lag; parallel paths used to mint a second UUID).
        let result = Chat.findOrCreate(
            for: user,
            in: context,
            touchLastMessageTimeOnCreate: true
        )
        if !result.created, result.chat.lastMessageTime == nil {
            result.chat.lastMessageTime = Date()
        }
        do {
            if context.hasChanges {
                try context.save()
            }
            chatToOpen = result.chat.id
        } catch {
            Log.error("openOrCreateChat: failed to save: \(error)", category: "ChatsViewModel")
        }
    }

    func toggleMute(chat: Chat) {
        guard let context = viewContext else { return }
        chat.isMuted.toggle()
        context.saveAndLog()
        Log.info("Chat \(chat.id) isMuted=\(chat.isMuted)", category: "ChatsViewModel")
    }

    /// Whether deleting a chat may also ask the peer to tear the session down.
    ///
    /// Only when this device is the account's only one. `nil` — we could not establish the device
    /// count — is treated as "there may be a sibling", because the two errors are not
    /// symmetrical.
    ///
    /// **Sending is the destructive direction, not withholding.** Delivery does not name the
    /// sending device (§D), so the peer applies an END_SESSION to whichever device its addressing
    /// resolves to — the account's pinned one. 2026-09-03: a Desktop linked minutes earlier
    /// deleted an empty chat, and the peer archived the **iPhone's** session; over the run all six
    /// of its archives landed on a device that had asked for nothing. A secondary device deleting
    /// a chat could destroy the primary's healthy session.
    ///
    /// Withholding costs the peer's forward-secrecy hygiene, not the deleting user's privacy: what
    /// "delete chat" promises is local, and `ChatManagementService.deleteChat` delivers it — it
    /// archives every stored session for that peer and cascades the messages away. The peer is
    /// merely left holding a ratchet nothing will use, which its own next re-init retires.
    ///
    /// This is an interim rule. The right behaviour is to tear down **this device's** session and
    /// say which device that is, and that needs §D.
    /// Exactly one, not "at most one": an account always contains the device asking, so a count of
    /// zero is a fetch that came back empty and must read the same as `nil`. `<= 1` would make the
    /// failure mode announce.
    /// `nonisolated`: it reads one argument and no actor state.
    nonisolated static func mayAnnounceTeardown(ownDeviceCount: Int?) -> Bool {
        ownDeviceCount == 1
    }

    func deleteChatWithEndSession(chat: Chat) async {
        // Logged before the first `await`, because everything after it can fail to arrive.
        // 2026-09-04: a chat was deleted in the UI, the app died on another screen moments later,
        // and the conversation was back after relaunch — with no line anywhere saying a delete had
        // been asked for.
        let requestedFor = chat.otherUser?.id
        Log.info(
            "Chat delete requested for \(requestedFor?.prefix(8).description ?? "unknown")…",
            category: "ChatsViewModel"
        )

        // The delete lands first, and on purpose. It is what the person asked for, it needs
        // nothing but the store, and the row has already left the list — so everything that can
        // block or die belongs *after* it. On 2026-09-04 it ran last: the app died two seconds
        // into the END_SESSION round trip and the conversation was back on the next launch, one
        // of two requested deletes in that session having survived.
        //
        // The session outlives this by design. `deleteChatLocally` removes rows and nothing else,
        // so the END_SESSION below still has a session to be encrypted with, and the archive runs
        // after it exactly as before.
        chatManagementService.deleteChatLocally(chat)

        if let userId = requestedFor {
            // The cache first, the network only when it is cold. Both answers are the same
            // `[DeviceBundleData]`, and `knownOwnDevices` returns `[]` on a stale or missing entry
            // — which `mayAnnounceTeardown` reads as "unknown", the non-announcing answer. So the
            // fetch is what a cold cache costs, not what every delete costs.
            let myUserId = AuthSessionManager.shared.currentUserId ?? ""
            var devices = MultiDeviceSendCoordinator.shared.knownOwnDevices(myUserId: myUserId)
            if devices.isEmpty {
                devices = await MultiDeviceSendCoordinator.shared.refreshOwnDevices(myUserId: myUserId)
            }
            if Self.mayAnnounceTeardown(ownDeviceCount: devices.isEmpty ? nil : devices.count) {
                do {
                    try await SessionLifecycleController.shared.sendEndSession(to: userId, reason: "chat_deleted")
                } catch {
                    Log.error("END_SESSION failed after chat delete (continuing): \(error)", category: "ChatsViewModel")
                }
            } else {
                Log.info(
                    "Chat delete for \(userId.prefix(8))…: not announcing teardown — \(devices.isEmpty ? "device set unknown" : "\(devices.count) device(s) on this account") and delivery cannot name which one asked",
                    category: "ChatsViewModel"
                )
            }
            // After the announce, never before: sending one needs the session this destroys.
            chatManagementService.archiveSessions(ofPeer: userId)
        }
        streamLifecycle.reconnectIfSubscriptionsChanged()
    }
}
