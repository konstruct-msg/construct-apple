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

    func pruneContact(userId: String) {
        chatManagementService.pruneContact(userId: userId)
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
        // been asked for. The durable part of this method is its last statement; the record that
        // it was wanted has to come first.
        let requestedFor = chat.otherUser?.id
        Log.info(
            "Chat delete requested for \(requestedFor?.prefix(8).description ?? "unknown")…",
            category: "ChatsViewModel"
        )
        if let userId = requestedFor {
            // The cache first, the network only when it is cold. Both answers are the same
            // `[DeviceBundleData]`, and `knownOwnDevices` returns `[]` on a stale or missing entry
            // — which `mayAnnounceTeardown` reads as "unknown", the non-announcing answer. So the
            // fetch is what a cold cache costs, not what every delete costs.
            //
            // It is not a micro-optimisation: until the local delete runs, the user has been shown
            // a chat disappearing that is still on disk, and each round trip in front of it widens
            // the window in which a crash, a kill or a stalled network makes that false.
            let myUserId = AuthSessionManager.shared.currentUserId ?? ""
            var devices = MultiDeviceSendCoordinator.shared.knownOwnDevices(myUserId: myUserId)
            if devices.isEmpty {
                devices = await MultiDeviceSendCoordinator.shared.refreshOwnDevices(myUserId: myUserId)
            }
            if Self.mayAnnounceTeardown(ownDeviceCount: devices.isEmpty ? nil : devices.count) {
                do {
                    try await SessionLifecycleController.shared.sendEndSession(to: userId, reason: "chat_deleted")
                } catch {
                    Log.error("END_SESSION failed before chat delete (continuing): \(error)", category: "ChatsViewModel")
                }
            } else {
                Log.info(
                    "Chat delete for \(userId.prefix(8))…: not announcing teardown — \(devices.isEmpty ? "device set unknown" : "\(devices.count) device(s) on this account") and delivery cannot name which one asked",
                    category: "ChatsViewModel"
                )
            }
        }
        chatManagementService.deleteChat(chat)
        streamLifecycle.reconnectIfSubscriptionsChanged()
    }
}
