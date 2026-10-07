//
//  ProfileSharingManager.swift
//  Construct Messenger
//
//  Manages profile sharing: parsing, handling, system messages
//  Extracted from ChatsViewModel as part of Phase 1.3 refactoring
//  Created on 2026-02-01
//

import Foundation
import CoreData
import GRPCCore

/// Manages profile sharing between users
@MainActor
class ProfileSharingManager {
    
    // MARK: - Singleton
    
    static let shared = ProfileSharingManager()
    
    private init() {}
    
    // MARK: - Profile Message Parsing
    
    /// Parse profile message from decrypted content (supports binary wire format + legacy JSON)
    /// - Parameter content: Decrypted message content (JSON string or binary)
    /// - Returns: ProfileShareData if valid profile message, nil otherwise
    func parseProfileMessage(_ content: String) -> ProfileShareData? {
        guard let data = content.data(using: .utf8) else {
            Log.debug("parseProfileMessage: Failed to convert content to data", category: "ProfileSharingManager")
            return nil
        }
        return parseProfileMessage(from: data)
    }

    /// Parse from binary Data (preferred for new sends) with legacy JSON fallback.
    func parseProfileMessage(from data: Data) -> ProfileShareData? {
        // Try binary first (new format, no JSON)
        if let profile = ProfileShareData.fromBinaryData(data) {
            Log.info("Successfully parsed profile message (binary): displayName=\(profile.displayName), avatarMediaId=\(profile.avatarMediaId ?? "nil")", category: "ProfileSharingManager")
            return profile
        }

        // Legacy JSON fallback
        guard let _ = String(data: data, encoding: .utf8) else { return nil }
        guard let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = jsonDict["type"] as? String,
              type == "profile" else {
            Log.debug("parseProfileMessage: Content is not a profile message", category: "ProfileSharingManager")
            return nil
        }

        do {
            let json = try JSONDecoder().decode(ProfileShareData.self, from: data)
            Log.info("Successfully parsed profile message (legacy JSON): displayName=\(json.displayName), avatarMediaId=\(json.avatarMediaId ?? "nil")", category: "ProfileSharingManager")
            return json
        } catch {
            Log.error("parseProfileMessage: Failed to decode ProfileShareData: \(error)", category: "ProfileSharingManager")
            return nil
        }
    }
    
    // MARK: - Profile Handling
    
    /// Handle incoming profile message (the untyped layout). Onto an existing row only.
    func handleProfileMessage(_ profileData: ProfileShareData, from userId: String) {
        let contacts = LocalRepositories.contacts
        guard let held = try? contacts.contact(userId) else {
            Log.error("User not found for profile update: \(userId)", category: "ProfileSharingManager")
            return
        }
        // An untyped profile carries the send time, not a version, so it cannot be ordered against
        // a typed one: once a typed profile is held, the old layout is a resend from a build that
        // predates the type, and applying it could put an older name back.
        guard held.profileEditedAtMs == 0 else {
            Log.info("Untyped profile from \(userId.prefix(8))… ignored — a typed profile is held", category: "ProfileSharingManager")
            return
        }

        // The name goes in at once, so the chat list shows it while the avatar downloads. The
        // generated name is no name (`ProfileShare.chosenName`): the username stays.
        let shared = profileData.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = DisplayNameGenerator.isGenerated(shared, for: userId) ? "" : shared
        do {
            try contacts.applySharedProfile(
                userId, displayName: trimmedName.isEmpty ? held.displayName : trimmedName,
                sharedWithMeAt: Date(), profileEditedAtMs: held.profileEditedAtMs
            )
            Log.info("Profile data updated for user \(userId): displayName=\(profileData.displayName)", category: "ProfileSharingManager")
        } catch {
            Log.error("Failed to save profile data: \(error)", category: "ProfileSharingManager")
            return
        }

        // The avatar. Priority: new format (Media Upload API) > old format (base64).
        if let avatarMediaId = profileData.avatarMediaId,
           let avatarMediaUrl = profileData.avatarMediaUrl,
           let avatarMediaKey = profileData.avatarMediaKey {
            let nameSnapshot = trimmedName
            Task {
                do {
                    Log.info("Downloading avatar from Media Upload API: \(avatarMediaId)", category: "ProfileSharingManager")
                    let decryptedData = try await MediaManager.shared.downloadAndDecryptAvatar(
                        mediaId: avatarMediaId,
                        mediaUrl: avatarMediaUrl,
                        mediaKey: avatarMediaKey
                    )
                    guard let live = try contacts.contact(userId) else { return }
                    // Re-apply the name in case a server username refresh raced the download.
                    try contacts.applySharedProfile(
                        userId, displayName: nameSnapshot.isEmpty ? live.displayName : nameSnapshot,
                        sharedWithMeAt: live.sharedWithMeAt ?? Date(), profileEditedAtMs: live.profileEditedAtMs
                    )
                    try contacts.setAvatar(
                        userId, decryptedData, pendingRef: live.pendingAvatarRef, pendingSince: live.pendingAvatarSince
                    )
                    Log.info("Avatar downloaded and saved for user \(userId)", category: "ProfileSharingManager")
                } catch {
                    Log.error("Failed to download avatar: \(error.localizedDescription)", category: "ProfileSharingManager")
                }
            }
        } else if let avatarBase64 = profileData.avatarData,
                  let avatarData = Data(base64Encoded: avatarBase64) {
            // Old format: base64 data (backward compatibility)
            do {
                try contacts.setAvatar(
                    userId, avatarData, pendingRef: held.pendingAvatarRef, pendingSince: held.pendingAvatarSince
                )
            } catch {
                Log.error("Failed to save avatar: \(error)", category: "ProfileSharingManager")
            }
        }
    }

    // MARK: - Typed profile (content type 29)

    /// A typed profile from `userId`, applied only if newer than the one held
    /// (`ProfileShare.decision`). Onto an existing row only: a sender must not be able to put a
    /// contact in our store by sending to us.
    ///
    /// `startDownload` is what happens to a newly pending avatar; a test passes a recorder so the
    /// rule can be checked without the media store.
    func apply(
        _ profile: ProfileShare,
        from userId: String,
        startDownload: (String) -> Void = { id in Task { await ProfileSharingManager.fetchPendingAvatar(of: id) } }
    ) {
        let contacts = LocalRepositories.contacts
        guard let held = try? contacts.contact(userId) else {
            Log.error("Profile from \(userId.prefix(8))… for a contact we do not hold", category: "ProfileSharingManager")
            return
        }
        guard let action = profile.decision(heldEditedAtMs: held.profileEditedAtMs) else {
            Log.info("Profile from \(userId.prefix(8))… not newer than the one held — ignored", category: "ProfileSharingManager")
            return
        }

        do {
            // A profile is the sender's whole state at its version: no chosen name means none, so
            // a name shared earlier is dropped and the username shows again — never the generated
            // name.
            try contacts.applySharedProfile(
                userId, displayName: profile.chosenName(of: userId) ?? "",
                sharedWithMeAt: Date(), profileEditedAtMs: Int64(clamping: profile.editedAtMs)
            )
            switch action {
            case .download(let ref):
                try contacts.setAvatar(userId, held.avatar, pendingRef: try? ref.stored(), pendingSince: Date())
            case .clear:
                try contacts.setAvatar(userId, nil, pendingRef: nil, pendingSince: nil)
            case .keep:
                break
            }
        } catch {
            Log.error("Failed to save profile from \(userId.prefix(8))…: \(error)", category: "ProfileSharingManager")
            return
        }
        if case .download = action {
            startDownload(userId)
        }
    }

    /// How long a pending avatar is worth asking for: the media store deletes everything after
    /// `MEDIA_FILE_TTL_SECONDS` (7 days), and an avatar is media like any other.
    static let pendingAvatarLifetime: TimeInterval = 7 * 24 * 3600

    /// Download the avatar a contact's profile named, if one is still pending. On success it
    /// replaces the avatar; if the store says the file is gone, or it is older than the store keeps
    /// anything, the reference is dropped and the avatar held stays. Any other failure leaves it
    /// pending for the next stream connect (`AvatarRetryService`).
    static func fetchPendingAvatar(of contactId: String) async {
        let contacts = LocalRepositories.contacts
        guard let held = try? contacts.contact(contactId), let stored = held.pendingAvatarRef else { return }
        let contact = contactId.prefix(8)
        if let since = held.pendingAvatarSince, Date().timeIntervalSince(since) > pendingAvatarLifetime {
            Log.info("Avatar of \(contact)… expired in the media store — dropped", category: "ProfileSharingManager")
            clearPending(contactId, ifStill: stored)
            return
        }
        guard let ref = ProfileShare.AvatarRef(stored: stored) else {
            clearPending(contactId, ifStill: stored)
            return
        }
        do {
            let data = try await MediaManager.shared.downloadAndDecryptAvatar(
                mediaId: ref.mediaId, mediaUrl: ref.mediaUrl, mediaKey: ref.mediaKey
            )
            // A newer profile may have named another avatar while this one downloaded.
            guard (try? contacts.contact(contactId))?.pendingAvatarRef == stored else { return }
            try? contacts.setAvatar(contactId, data, pendingRef: nil, pendingSince: nil)
            Log.info("Avatar of \(contact)… downloaded", category: "ProfileSharingManager")
        } catch let error as RPCError where error.code == .notFound {
            Log.info("Avatar of \(contact)… is gone from the media store — dropped", category: "ProfileSharingManager")
            clearPending(contactId, ifStill: stored)
        } catch {
            Log.info("Avatar of \(contact)… not downloaded (\(error.localizedDescription)) — retried on reconnect", category: "ProfileSharingManager")
        }
    }

    /// The pending reference goes, the avatar held stays — unless a newer profile has named
    /// another one meanwhile.
    private static func clearPending(_ contactId: String, ifStill stored: Data) {
        let contacts = LocalRepositories.contacts
        guard let live = try? contacts.contact(contactId), live.pendingAvatarRef == stored else { return }
        try? contacts.setAvatar(contactId, live.avatar, pendingRef: nil, pendingSince: nil)
    }
}
