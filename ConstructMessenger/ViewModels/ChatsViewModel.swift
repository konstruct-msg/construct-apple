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
    /// Desktop: ⌘F in an open chat presents the transcript search field.
    var chatSearchPresented: Bool = false
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
        PersistentACKStore.shared.pruneExpired(in: context)
        // `SessionHealingService.restoreQueueState` / `pruneExpired` stood here until 2026-09-23.
        // Both served a second healing queue this app kept beside the core's; the core restores
        // and prunes its own with the orchestrator state. What is left is the rows a previous
        // build wrote — see `HealingMessage`.
        HealingMessagePurge.runOnce(in: context)
    }

    // MARK: - Stream (pass-throughs for external callers)

    func startMessageStream() {
        streamLifecycle.startMessageStream()
    }

    func stopMessageStream() {
        streamLifecycle.stopMessageStream()
    }

    // MARK: - Chat operations

    /// Open the chat for a verified invite: the contact, their pinned identity key and their
    /// account address in one step.
    ///
    /// Every redeem surface calls this rather than building a `PublicUserInfo` itself. Seven of
    /// them used to, each listing the same fields and passing the identity key on — an eighth
    /// field added to seven copies is seven chances to drop it, and a dropped address does not
    /// fail: the contact is simply written to by the server-assigned id forever.
    func startChat(
        redeeming info: ContactInfo,
        origin: SessionReducer.ChatStartOrigin = .existingContact
    ) -> Chat? {
        let user = PublicUserInfo(
            id: info.userId,
            username: info.username,
            avatarUrl: nil,
            bio: nil,
            deviceId: info.deviceId
        )
        return startChat(
            with: user,
            identityPublicKey: info.identityPublicKey,
            accountAddress: info.accountAddress,
            origin: origin
        )
    }

    func startChat(
        with user: PublicUserInfo,
        identityPublicKey: Data? = nil,
        accountAddress: Data? = nil,
        origin: SessionReducer.ChatStartOrigin = .existingContact
    ) -> Chat? {
        let chat = chatManagementService.startChat(
            with: user,
            identityPublicKey: identityPublicKey,
            accountAddress: accountAddress
        )
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
        } else if !CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: user.id) {
            CryptoManager.shared.clearArchivedSessionsForAllDevices(ofPeer: user.id)
            SessionLifecycleController.shared.prewarmSessions(for: [user.id])
        }
        return chat
    }

    func deleteChat(chat: Chat) {
        chatManagementService.deleteChat(chat)
    }

    /// Remove a contact from this device. Local only: nothing is sent.
    ///
    /// Until 2026-09-27 it announced an END_SESSION, because silence made the state
    /// unrecoverable: `MessageRouter` resurrects a pruned contact when a **handshake** arrives,
    /// and a peer on a healthy session never sends one (2026-09-04: msgNum 1–5 dropped, every one
    /// *sent* on their screen). The peer's next message is answered instead now — the core, which
    /// has forgotten the session, sends it a decryption error, the peer opens a new state, and its
    /// handshake brings the contact back (`decisions/sessions-renew-by-sending.md`).
    ///
    /// Refusing someone is the block button's job, and the server enforces it before delivery.
    /// This control answers "what do I keep", not "what may they do".
    func pruneContact(userId: String) async {
        Log.info("Contact prune requested for \(userId.prefix(8))…", category: "ChatsViewModel")

        // Every device of this contact, resolved **before** anything local is destroyed.
        //
        // `deviceIds(ofPeer:)` prefers `PeerDevice` rows — which survive the prune, having no
        // relationship to `User` — but falls back to `pinnedDevice(ofPeer:)`, and that reads
        // `User.knownIdentityKey`, which does not. So for a contact we hold no `PeerDevice` row
        // for, which is every peer we have only ever received from, resolving after the prune
        // returns nothing. `archiveSessions(ofPeer:)` ran in exactly that position and archived
        // nothing for those contacts.
        let context = PersistenceController.shared.container.viewContext
        let peerDevices = SessionAddressing.deviceIds(ofPeer: userId, in: context)

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
        // The second heal record this app used to keep is gone (step 4, 2026-09-23):
        // `forgetContactState` above drops the core's, which is now the only one.

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

    /// Delete a chat and forget the sessions with its peer. Local only: nothing is sent — the
    /// peer's next message is answered with a decryption error, and the state it opens then is a
    /// new one (`decisions/sessions-renew-by-sending.md`). Until 2026-09-27 this announced an
    /// END_SESSION, and only from an account's single device, because the peer could not tell
    /// which of our devices asked.
    func deleteChatForgettingSessions(chat: Chat) async {
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
        // nothing but the store, and the row has already left the list. On 2026-09-04 it ran last,
        // behind a network round trip, and a delete did not survive the app dying inside it.
        chatManagementService.deleteChatLocally(chat)

        if let userId = requestedFor {
            chatManagementService.archiveSessions(ofPeer: userId)
        }
        streamLifecycle.reconnectIfSubscriptionsChanged()
    }
}
