//
//  ProfileShareViewModel.swift
//  Construct Messenger
//
//  ViewModel for managing profile data sharing
//

import Foundation
import CoreData
#if canImport(UIKit)
import UIKit
#endif
import Observation

@MainActor
@Observable
class ProfileShareViewModel {
    private var viewContext: NSManagedObjectContext?
    private var isSharingProfile = false
    /// Who sends a profile to one contact: `deliver` unless a test stands in, so a rebroadcast can
    /// be checked to reach every contact without a server.
    typealias Deliver = (OutgoingProfile, String) async -> (Bool, String?)
    private var deliverOverride: Deliver?

    init() {}

    init(context: NSManagedObjectContext, deliver: Deliver? = nil) {
        self.viewContext = context
        self.deliverOverride = deliver
    }

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }
    
    /// Our profile as it goes out: the name we go by and, when we have one, the avatar — already
    /// uploaded, so the profile only names it.
    struct OutgoingProfile {
        let senderId: String
        let data: ProfileShare
    }

    /// Set when a profile went out without the avatar because the upload failed: the avatar was
    /// left as "unchanged" rather than sent as removed, so contacts keep the old one, and the
    /// rebroadcast is owed until it succeeds. Consumed on the next stream connect.
    private static let rebroadcastOwedKey = "profileRebroadcastOwed"
    static var rebroadcastOwed: Bool {
        get { UserDefaults.standard.bool(forKey: rebroadcastOwedKey) }
        set { UserDefaults.standard.set(newValue, forKey: rebroadcastOwedKey) }
    }

    /// Rebroadcast if an earlier one went out without its avatar. Called on stream connect.
    static func rebroadcastIfOwed() async {
        guard rebroadcastOwed else { return }
        rebroadcastOwed = false
        Log.info("Profile rebroadcast owed from a failed avatar upload — sending again", category: "ProfileShare")
        let shareVM = ProfileShareViewModel(context: PersistenceController.shared.container.viewContext)
        await shareVM.rebroadcastProfileToSharedContacts()
    }

    /// Share profile (displayName and avatar) with another user via E2E encrypted message.
    /// Avatar is uploaded via Media Upload API to avoid size limitations.
    ///
    /// The toggle's entry point. A second tap while the first is under way is ignored — and now
    /// says so through `completion`, which it used to skip, leaving its caller waiting forever.
    func shareProfile(with userId: String, completion: @escaping (Bool, String?) -> Void) {
        guard !isSharingProfile else {
            Log.info("Profile share already in progress, ignoring duplicate", category: "ProfileShare")
            completion(false, nil)
            return
        }
        isSharingProfile = true
        Task { @MainActor in
            defer { self.isSharingProfile = false }
            guard let profile = await self.prepareProfile() else {
                completion(false, NSLocalizedString("user_not_found", comment: ""))
                return
            }
            let (success, error) = await self.deliver(profile, to: userId)
            completion(success, error)
        }
    }

    /// Snapshot our name and avatar, and upload the avatar. Nil when there is no signed-in user.
    ///
    /// The avatar goes as one of three states (`ProfileShare.Avatar`): uploaded → `set`; we have
    /// none → `removed`, so a contact holding an old one clears it; the upload failed → `unchanged`,
    /// so contacts keep what they have, and the rebroadcast is owed (`rebroadcastOwed`). Before
    /// 2026-10-02 the last two were the same message, and no contact ever cleared an avatar.
    ///
    /// The `Task`s that send it hold `self` strongly on purpose. Until 2026-10-02 they captured it
    /// weakly (`463a8533`, 2026-04-10), and `rebroadcastProfileToSharedContacts` runs on a view
    /// model made for that one call and released as soon as it returned — so every send found
    /// `self` gone and returned without a word. A changed name or avatar reached no contact at
    /// all; before April, the `isSharingProfile` guard let it reach the first one only.
    func prepareProfile() async -> OutgoingProfile? {
        guard let context = viewContext,
              let currentUserId = AuthSessionManager.shared.currentUserId else { return nil }

        let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
        userFetchRequest.predicate = NSPredicate(format: "id == %@", currentUserId)
        guard let currentUser = try? context.fetch(userFetchRequest).first else { return nil }

        // A profile that has never been stamped (edited before the stamp existed) gets one now,
        // once, and keeps it: what makes it a version is that sending again does not change it.
        if currentUser.profileEditedAtMs == 0 {
            currentUser.markProfileEdited()
            try? context.save()
        }

        // Snapshot values we need before any await — NSManagedObject must not be
        // read off MainActor after suspension points.
        // Only a name we chose, or our username: never the generated one, which a contact
        // computes for itself and would take for a name we picked (`ProfileShare.chosenName`).
        let displayName = DisplayNameGenerator.isGenerated(currentUser.displayName, for: currentUserId)
            ? currentUser.username
            : (currentUser.displayName.isEmpty ? currentUser.username : currentUser.displayName)
        let editedAtMs = UInt64(currentUser.profileEditedAtMs)
        let avatarImage = currentUser.avatarData.flatMap { ImageHelper.imageFromData($0) }

        let avatar: ProfileShare.Avatar
        if let avatarImage {
            do {
                let upload = try await MediaManager.shared.uploadAvatar(avatarImage)
                avatar = .set(ProfileShare.AvatarRef(
                    mediaId: upload.mediaId,
                    mediaUrl: upload.mediaUrl,
                    mediaKey: upload.encryptionKey,
                    mimeType: "image/jpeg"
                ))
                Log.info("Avatar uploaded: \(upload.mediaId)", category: "ProfileShare")
            } catch {
                Log.error("Failed to upload avatar: \(error.localizedDescription) — profile goes with the avatar unchanged, rebroadcast owed", category: "ProfileShare")
                avatar = .unchanged
                Self.rebroadcastOwed = true
            }
        } else {
            avatar = .removed
        }

        return OutgoingProfile(
            senderId: currentUserId,
            data: ProfileShare(displayName: displayName, editedAtMs: editedAtMs, avatar: avatar)
        )
    }

    /// [profile] to every device of [userId]. True when a device of theirs took it.
    func deliver(_ profile: OutgoingProfile, to userId: String) async -> (Bool, String?) {
        // Check if session is ready; if not, initialize it on-demand
        if !CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId) {
            Log.info("No session for \(userId) — initializing before profile share", category: "ProfileShare")
            let service = SessionInitializationService.shared
            do {
                // Real X3DH init (no session yet) — legitimately consumes an OTPK.
                let bundle = try await service.fetchPublicKeyWithRetry(userId: userId, consumeOneTimePrekey: true)
                do {
                    try service.initializeSession(userId: userId, bundle: bundle)
                } catch SessionError.peerSPKStale {
                    // Contact offline too long to rotate their SPK — degrade so the profile
                    // still shares. Flags the session at-risk (see stale-peer-reachability).
                    try service.initializeSession(userId: userId, bundle: bundle, allowStale: true)
                }
                Log.info("Session initialized for profile share with \(userId)", category: "ProfileShare")
            } catch {
                Log.error("Failed to initialize session for profile share: \(error)", category: "ProfileShare")
                return (false, NSLocalizedString("failed_to_establish_session", comment: ""))
            }
        }

        // Content type 29 in KNST byte 5, inside the ciphertext: the receiver no longer has to
        // guess a profile from its bytes, and the server sees a generic envelope as before.
        let payload: Data
        do {
            payload = try profile.data.encoded()
        } catch {
            Log.error("Profile did not encode: \(error)", category: "ProfileShare")
            return (false, error.localizedDescription)
        }
        let messageId = UUID().uuidString.lowercased()
        let plan: ChunkedMessagePlan = .whole(payload, contentType: 29, messageId: UUID(uuidString: messageId) ?? UUID())

        do {
            // Every device of theirs. Until 2026-09-22 this reached the pinned one only, so a
            // peer's second device never learned our name or avatar.
            let response = try await OutboundMessagePipeline.shared.sendToRecipientDevices(
                plan: plan,
                baseMessageId: messageId,
                senderId: profile.senderId,
                recipientId: userId,
                timestamp: UInt64(Date().timeIntervalSince1970)
            ).status
            if response.status.lowercased() == "blocked" {
                Log.error("Profile share rejected — sender is blocked by \(userId.prefix(8))…", category: "ProfileShare")
                return (false, "blocked")
            }
            Log.info("Profile shared with user \(userId) via gRPC: \(response.messageId)", category: "ProfileShare")
            return (true, nil)
        } catch {
            Log.error("Failed to send profile message via gRPC: \(error.localizedDescription)", category: "ProfileShare")
            return (false, error.localizedDescription)
        }
    }
    
    // MARK: - Avatar rebroadcast

    /// Re-send current profile (including updated avatar) to all contacts we are sharing with.
    /// Call this whenever the user changes their avatar or display name so contacts stay in sync.
    ///
    /// One profile, the avatar uploaded once, then each contact in turn — awaited, so the caller's
    /// `Task` keeps this view model alive until the last one is sent. Failures are logged and do
    /// not stop the others.
    func rebroadcastProfileToSharedContacts() async {
        guard viewContext != nil,
              let currentUserId = AuthSessionManager.shared.currentUserId else { return }

        // The contacts we have chosen to share our profile with
        let contactIds = (try? LocalRepositories.contacts.sharingWith(except: currentUserId)) ?? []
        guard !contactIds.isEmpty else {
            Log.info("No contacts to rebroadcast profile to", category: "ProfileShare")
            return
        }

        Log.info("Rebroadcasting profile to \(contactIds.count) contact(s)", category: "ProfileShare")

        guard let profile = await prepareProfile() else {
            Log.error("Profile rebroadcast: no signed-in user", category: "ProfileShare")
            return
        }
        for contactId in contactIds {
            let (success, error): (Bool, String?)
            if let deliverOverride {
                (success, error) = await deliverOverride(profile, contactId)
            } else {
                (success, error) = await deliver(profile, to: contactId)
            }
            if success {
                Log.info("Profile rebroadcast to \(contactId.prefix(8))", category: "ProfileShare")
            } else {
                Log.error("Profile rebroadcast to \(contactId.prefix(8)) failed: \(error ?? "unknown")", category: "ProfileShare")
            }
        }
    }
}
