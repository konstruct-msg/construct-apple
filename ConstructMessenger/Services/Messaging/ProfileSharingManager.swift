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
    
    /// Handle incoming profile message
    /// - Parameters:
    ///   - profileData: Parsed profile data
    ///   - userId: User ID who sent the profile
    ///   - context: Core Data context
    func handleProfileMessage(
        _ profileData: ProfileShareData,
        from userId: String,
        in context: NSManagedObjectContext
    ) {
        let userFetchRequest = User.fetchRequest()
        // Combine with additional predicate
        let userIdPredicate = NSPredicate(format: "id == %@", userId)
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [userIdPredicate])
        
        guard let user = try? context.fetch(userFetchRequest).first else {
            Log.error("User not found for profile update: \(userId)", category: "ProfileSharingManager")
            return
        }
        // An untyped profile carries the send time, not a version, so it cannot be ordered against
        // a typed one: once a typed profile is held, the old layout is a resend from a build that
        // predates the type, and applying it could put an older name back.
        guard user.profileEditedAtMs == 0 else {
            Log.info("Untyped profile from \(userId.prefix(8))… ignored — a typed profile is held", category: "ProfileSharingManager")
            return
        }
        
        // Update display name immediately so chat list / headers show the real name
        // even while the avatar is still downloading.
        // The generated name is no name (`ProfileShare.chosenName`): the username stays.
        let shared = profileData.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = DisplayNameGenerator.isGenerated(shared, for: userId) ? "" : shared
        if !trimmedName.isEmpty {
            user.displayName = trimmedName
        }

        // Always mark sharing now — name is already trusted; avatar may arrive async.
        user.isSharingWithMe = true
        user.sharedWithMeAt = Date()

        // Update avatar if provided
        // Priority: new format (Media Upload API) > old format (base64)
        if let avatarMediaId = profileData.avatarMediaId,
           let avatarMediaUrl = profileData.avatarMediaUrl,
           let avatarMediaKey = profileData.avatarMediaKey {
            // New format: download and decrypt media from Media Upload API
            // Capture objectID to safely re-fetch after async boundary.
            // Use viewContext for the save — the passed `context` may be a short-lived
            // background context that's deallocated before the download completes.
            let userObjectID = user.objectID
            let nameSnapshot = trimmedName
            Task {
                do {
                    Log.info("Downloading avatar from Media Upload API: \(avatarMediaId)", category: "ProfileSharingManager")

                    let decryptedData = try await MediaManager.shared.downloadAndDecryptAvatar(
                        mediaId: avatarMediaId,
                        mediaUrl: avatarMediaUrl,
                        mediaKey: avatarMediaKey
                    )

                    await MainActor.run {
                        let viewContext = PersistenceController.shared.container.viewContext
                        guard let liveUser = viewContext.object(with: userObjectID) as? User else { return }
                        // Re-apply name in case a server username refresh raced the download.
                        if !nameSnapshot.isEmpty {
                            liveUser.displayName = nameSnapshot
                        }
                        liveUser.avatarData = decryptedData
                        liveUser.isSharingWithMe = true
                        liveUser.sharedWithMeAt = liveUser.sharedWithMeAt ?? Date()

                        do {
                            try viewContext.save()
                            Log.info("Avatar downloaded and saved for user \(userId)", category: "ProfileSharingManager")
                        } catch {
                            Log.error("Failed to save avatar: \(error)", category: "ProfileSharingManager")
                        }
                    }
                } catch {
                    Log.error("Failed to download avatar: \(error.localizedDescription)", category: "ProfileSharingManager")
                }
            }
        } else if let avatarBase64 = profileData.avatarData,
                  let avatarData = Data(base64Encoded: avatarBase64) {
            // Old format: base64 data (backward compatibility)
            user.avatarData = avatarData
        }

        do {
            try context.save()
            Log.info("Profile data updated for user \(userId): displayName=\(profileData.displayName)", category: "ProfileSharingManager")
            Log.debug("Chat list row should refresh — User.displayName/avatarData changed", category: "ProfileSharingManager")
        } catch {
            Log.error("Failed to save profile data: \(error)", category: "ProfileSharingManager")
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
        in context: NSManagedObjectContext,
        startDownload: (NSManagedObjectID) -> Void = { id in Task { await ProfileSharingManager.fetchPendingAvatar(of: id) } }
    ) {
        let request = User.fetchRequest()
        request.predicate = NSPredicate(format: "id == %@", userId)
        request.fetchLimit = 1
        guard let user = try? context.fetch(request).first else {
            Log.error("Profile from \(userId.prefix(8))… for a contact we do not hold", category: "ProfileSharingManager")
            return
        }
        guard let action = profile.decision(heldEditedAtMs: user.profileEditedAtMs) else {
            Log.info("Profile from \(userId.prefix(8))… not newer than the one held — ignored", category: "ProfileSharingManager")
            return
        }

        // A profile is the sender's whole state at its version: no chosen name means none, so a
        // name shared earlier is dropped and the username shows again — never the generated name.
        user.displayName = profile.chosenName(of: userId) ?? ""
        user.isSharingWithMe = true
        user.sharedWithMeAt = Date()
        user.profileEditedAtMs = Int64(clamping: profile.editedAtMs)

        switch action {
        case .download(let ref):
            user.pendingAvatarRef = try? ref.stored()
            user.pendingAvatarSince = Date()
        case .clear:
            user.avatarData = nil
            user.pendingAvatarRef = nil
            user.pendingAvatarSince = nil
        case .keep:
            break
        }

        do {
            try context.save()
        } catch {
            Log.error("Failed to save profile from \(userId.prefix(8))…: \(error)", category: "ProfileSharingManager")
            return
        }
        if case .download = action {
            startDownload(user.objectID)
        }
    }

    /// How long a pending avatar is worth asking for: the media store deletes everything after
    /// `MEDIA_FILE_TTL_SECONDS` (7 days), and an avatar is media like any other.
    static let pendingAvatarLifetime: TimeInterval = 7 * 24 * 3600

    /// Download the avatar a contact's profile named, if one is still pending. On success it
    /// replaces the avatar; if the store says the file is gone, or it is older than the store keeps
    /// anything, the reference is dropped and the avatar held stays. Any other failure leaves it
    /// pending for the next stream connect (`AvatarRetryService`).
    static func fetchPendingAvatar(of objectID: NSManagedObjectID) async {
        let viewContext = PersistenceController.shared.container.viewContext
        guard let user = viewContext.object(with: objectID) as? User,
              let stored = user.pendingAvatarRef else { return }
        let contact = user.id.prefix(8)
        if let since = user.pendingAvatarSince, Date().timeIntervalSince(since) > pendingAvatarLifetime {
            Log.info("Avatar of \(contact)… expired in the media store — dropped", category: "ProfileSharingManager")
            clearPending(user, ifStill: stored, in: viewContext)
            return
        }
        guard let ref = ProfileShare.AvatarRef(stored: stored) else {
            clearPending(user, ifStill: stored, in: viewContext)
            return
        }
        do {
            let data = try await MediaManager.shared.downloadAndDecryptAvatar(
                mediaId: ref.mediaId, mediaUrl: ref.mediaUrl, mediaKey: ref.mediaKey
            )
            // A newer profile may have named another avatar while this one downloaded.
            guard user.pendingAvatarRef == stored else { return }
            user.avatarData = data
            clearPending(user, ifStill: stored, in: viewContext)
            Log.info("Avatar of \(contact)… downloaded", category: "ProfileSharingManager")
        } catch let error as RPCError where error.code == .notFound {
            Log.info("Avatar of \(contact)… is gone from the media store — dropped", category: "ProfileSharingManager")
            clearPending(user, ifStill: stored, in: viewContext)
        } catch {
            Log.info("Avatar of \(contact)… not downloaded (\(error.localizedDescription)) — retried on reconnect", category: "ProfileSharingManager")
        }
    }

    private static func clearPending(_ user: User, ifStill stored: Data, in context: NSManagedObjectContext) {
        guard user.pendingAvatarRef == stored else { return }
        user.pendingAvatarRef = nil
        user.pendingAvatarSince = nil
        try? context.save()
    }
}
