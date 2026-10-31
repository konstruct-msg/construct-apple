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
    /// Puts our avatar on the media server — one new object per call. A test stands in.
    typealias UploadAvatar = (PlatformImage) async throws -> AvatarUploadResult
    private var uploadAvatar: UploadAvatar = { try await MediaManager.shared.uploadAvatar($0) }
    /// Waits between two contacts of a rebroadcast. A test stands in.
    typealias Pause = (Duration) async -> Void
    private var pause: Pause = { try? await Task.sleep(for: $0) }

    init() {}

    init(context: NSManagedObjectContext, deliver: Deliver? = nil,
         uploadAvatar: UploadAvatar? = nil, pause: Pause? = nil) {
        self.viewContext = context
        self.deliverOverride = deliver
        if let uploadAvatar { self.uploadAvatar = uploadAvatar }
        if let pause { self.pause = pause }
    }

    /// The wait before each contact after the first. Sends in one burst would tell the server
    /// "one account, N recipients, now" even with every avatar a separate object (TODO 144).
    static let rebroadcastSpacing: ClosedRange<Double> = 2...12

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

    /// This device's user removed their photo. Per account, on this device only: another device
    /// of the same account does not have the bytes, and "no bytes here" is not a removal.
    private static func avatarRemovedKey(for accountId: String) -> String {
        "profileAvatarRemoved.\(accountId.lowercased())"
    }

    static func isAvatarRemoved(accountId: String) -> Bool {
        UserDefaults.standard.bool(forKey: avatarRemovedKey(for: accountId))
    }

    static func setAvatarRemoved(_ removed: Bool, accountId: String) {
        let key = avatarRemovedKey(for: accountId)
        if removed {
            UserDefaults.standard.set(true, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
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
    /// The avatar goes as one of three states (`ProfileShare.Avatar`): uploaded → `set`; this
    /// device's user removed it (`isAvatarRemoved`) → `removed`, so a contact holding one clears
    /// it; anything else → `unchanged`, so contacts keep what they have. "Anything else" is an
    /// upload that failed (the rebroadcast is then owed) and a device that simply has no bytes —
    /// a second device never received the photo. Treating that as removal, and stamping the
    /// version "now" so the message wins, erased the photo a contact had just saved
    /// (2026-10-31). Before 2026-10-02 a failed upload and a removal were the same message, and
    /// no contact ever cleared an avatar.
    ///
    /// The `Task`s that send it hold `self` strongly on purpose. Until 2026-10-02 they captured it
    /// weakly (`463a8533`, 2026-04-10), and `rebroadcastProfileToSharedContacts` runs on a view
    /// model made for that one call and released as soon as it returned — so every send found
    /// `self` gone and returned without a word. A changed name or avatar reached no contact at
    /// all; before April, the `isSharingProfile` guard let it reach the first one only.
    func prepareProfile() async -> OutgoingProfile? {
        guard viewContext != nil,
              let currentUserId = AuthSessionManager.shared.currentUserId,
              var me = try? LocalRepositories.ownProfile.profile(accountId: currentUserId) else { return nil }

        // Only a name we chose, or our username: never the generated one, which a contact
        // computes for itself and would take for a name we picked (`ProfileShare.chosenName`).
        let displayName = DisplayNameGenerator.isGenerated(me.displayName, for: currentUserId)
            ? me.username
            : (me.displayName.isEmpty ? me.username : me.displayName)
        let avatarImage = me.avatar.flatMap { ImageHelper.imageFromData($0) }
        let removed = avatarImage == nil && Self.isAvatarRemoved(accountId: currentUserId)
        // A profile that has never been stamped gets one when this device actually has a photo
        // or recorded a removal. Stamping a device that has neither would make "now" newer than
        // the device that set the photo, and the contact would keep this empty version.
        if me.profileEditedAtMs == 0 && (avatarImage != nil || removed) {
            me.markEdited()
            try? LocalRepositories.ownProfile.save(me)
        }
        let editedAtMs = UInt64(me.profileEditedAtMs)

        let avatar: ProfileShare.Avatar
        if let avatarImage {
            Self.setAvatarRemoved(false, accountId: currentUserId)
            do {
                let upload = try await uploadAvatar(avatarImage)
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
        } else if removed {
            avatar = .removed
        } else {
            Log.info("No avatar on this device — profile leaves the contact's avatar unchanged", category: "ProfileShare")
            avatar = .unchanged
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
            return (false, error.userFacingMessage)
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
            return (false, error.userFacingMessage)
        }
    }
    
    // MARK: - Block and report

    /// Report the contact for spam and block them. Reporting feeds the server-side
    /// auto-escalation (flag/ban) engine; we also block (report-and-block is the safe default —
    /// you should not keep receiving messages from someone you reported). The reported device id
    /// is derived locally from the peer's identity key (`SHA256(identity_public)[0..16]`, the same
    /// value the server keys sentinel on), so it works even under sealed sender.
    /// True when the report reached the server.
    func blockAndReport(userId: String, knownIdentityKey: Data?) async -> Bool {
        let reportedDeviceId: String? = knownIdentityKey.map { deriveDeviceId(identityPublicKey: $0) }

        // Block immediately (local drop + durable server-side); report best-effort alongside.
        do {
            _ = try LocalRepositories.contacts.setBlocked(userId, true)
        } catch {
            Log.error("Contact \(userId.prefix(8))… not saved: \(error)", category: "UserProfileView")
        }

        var reported = false
        if let reportedDeviceId, !reportedDeviceId.isEmpty {
            do {
                reported = try await SentinelServiceClient.shared.reportSpam(reportedDeviceId: reportedDeviceId)
            } catch {
                Log.error("reportSpam failed for \(userId.prefix(8))…: \(error)", category: "UserProfileView")
            }
        } else {
            Log.error("reportSpam skipped for \(userId.prefix(8))… — no known identity key to derive device id", category: "UserProfileView")
        }
        BlockSyncService.shared.request(userId, blocked: true, reason: "spam")
        return reported
    }

    // MARK: - Session security summary

    struct SessionSecuritySummary: Equatable {
        let hasSession: Bool
        let suiteLabel: String
    }

    /// Human-readable name of the session's NEGOTIATED crypto suite. Must stay in
    /// lockstep with `SuiteID` in construct-core `crypto/suite_id.rs` — the previous
    /// hardcode here claimed Kyber for suite 1 (plain classic) and didn't know
    /// suite 3 at all.
    static func cryptoSuiteName(suiteId: Int) -> String {
        switch suiteId {
        case 1: return "X25519 · ChaCha20-Poly1305"
        case 2: return "PQ Hybrid · X25519+ML-KEM-768 · ML-DSA-65"
        case 3: return "X25519 · ChaCha20-Poly1305 · PQ Ratchet (ML-KEM-768)"
        default: return "Suite \(suiteId)"
        }
    }

    /// The card's security line from what the core reported — no I/O, so a test can drive it.
    static func sessionSecuritySummary(sessionExists: Bool, suiteId: Int, preV2Handshake: Bool) -> SessionSecuritySummary {
        guard sessionExists && suiteId > 0 else {
            return SessionSecuritySummary(
                hasSession: sessionExists,
                suiteLabel: NSLocalizedString("session_crypto_no_session", comment: ""))
        }
        var label = cryptoSuiteName(suiteId: suiteId)
        if preV2Handshake {
            label += " · PQXDH degraded"
        }
        return SessionSecuritySummary(hasSession: true, suiteLabel: label)
    }

    func sessionSecurity(ofPeer userId: String) -> SessionSecuritySummary {
        let sessionExists = SessionLifecycleController.shared.hasActiveSession(for: userId)
        // Real negotiated suite from the Rust core (Keychain only as fallback) —
        // suite 3 is negotiated per-session and never appears in the peer's bundle.
        let suiteId = Int(CryptoManager.shared.sessionSuiteIdAcrossDevices(ofPeer: userId))
        // A session opened before PQXDH v2 has no ML-KEM in its first key (or only the old
        // deferred contribution) until the upgrade sweep replaces it. The core's health report
        // says which, per device; the Keychain flag this read before is gone with the path
        // that set it.
        let preV2 = sessionExists && suiteId > 0 && SessionAddressing.deviceIds(ofPeer: userId).contains { device in
            CryptoManager.shared.getSessionHealth(for: device).map { $0.pqHandshake != .initialV2 } ?? false
        }
        return Self.sessionSecuritySummary(sessionExists: sessionExists, suiteId: suiteId, preV2Handshake: preV2)
    }

    // MARK: - Avatar rebroadcast

    /// Re-send current profile (including updated avatar) to all contacts we are sharing with.
    /// Call this whenever the user changes their avatar or display name so contacts stay in sync.
    ///
    /// Each contact in turn, in a random order, a few seconds apart, and each with its own upload of
    /// the avatar — awaited, so the caller's `Task` keeps this view model alive until the last one
    /// is sent. Failures are logged and do not stop the others.
    ///
    /// Until 2026-10-13 the avatar was uploaded once and that one object went to every contact:
    /// the server saw one object of ours fetched from N connections — not just who our contacts
    /// are, but whom we share our profile with (owner, TODO 144). A separate, equally long object
    /// per contact, sent apart, takes away "the same thing to N people at once". It does not take
    /// away that each upload is ours: the upload token names the account — that is the anonymous
    /// upload decision, not this.
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

        for (index, contactId) in contactIds.shuffled().enumerated() {
            if index > 0 {
                await pause(.seconds(Double.random(in: Self.rebroadcastSpacing)))
            }
            guard let profile = await prepareProfile() else {
                Log.error("Profile rebroadcast: no signed-in user", category: "ProfileShare")
                return
            }
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
