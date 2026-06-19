//
//  AvatarRetryService.swift
//  Construct Messenger
//
//  Retries failed avatar downloads after reconnect.
//
//  When a profile message arrives while the network is unavailable (e.g. during
//  the VEIL startup window), the avatar download fails and avatarData stays nil.
//  The download metadata (mediaId/Url/Key) is already persisted in the
//  corresponding Message.decryptedContent JSON — so on the next successful
//  stream connection we scan for users with missing avatars and retry.
//

import Foundation
import CoreData

final class AvatarRetryService {
    static let shared = AvatarRetryService()
    private init() {}

    private var isRetrying = false

    // MARK: - Public API

    /// Call after every successful stream (re)connect and at app launch post-auth.
    func retryPendingAvatarsIfNeeded() {
        guard !isRetrying else { return }
        Task { await retryAll() }
    }

    // MARK: - Core Logic

    private func retryAll() async {
        guard !isRetrying else { return }
        isRetrying = true
        defer { isRetrying = false }

        let context = PersistenceController.shared.container.viewContext
        let usersNeedingAvatar = await fetchUsersWithMissingAvatar(context: context)

        guard !usersNeedingAvatar.isEmpty else { return }
        Log.info("AvatarRetry: \(usersNeedingAvatar.count) user(s) missing avatar — scanning profile messages", category: "AvatarRetry")

        for userObjectID in usersNeedingAvatar {
            await retryAvatarForUser(objectID: userObjectID, context: context)
        }
    }

    @MainActor
    private func fetchUsersWithMissingAvatar(context: NSManagedObjectContext) -> [NSManagedObjectID] {
        let request = User.fetchRequest()
        request.predicate = NSPredicate(
            format: "isSharingWithMe == YES AND avatarData == nil"
        )
        request.returnsObjectsAsFaults = false
        let users = (try? context.fetch(request)) ?? []
        return users.map(\.objectID)
    }

    private func retryAvatarForUser(objectID: NSManagedObjectID, context: NSManagedObjectContext) async {
        // Fetch the most recent profile message for this user.
        // Profile messages are stored with decryptedContent containing `"type":"profile"`.
        let userId: String = await MainActor.run {
            (context.object(with: objectID) as? User)?.id ?? ""
        }
        guard !userId.isEmpty else { return }

        let profileJSON = await fetchLatestProfileMessageContent(userId: userId, context: context)
        guard let json = profileJSON else {
            Log.debug("AvatarRetry: no profile message found for \(userId.prefix(8))…", category: "AvatarRetry")
            return
        }

        guard let data = json.data(using: .utf8),
              let profileData = ProfileShareData.fromBinaryData(data) ?? (try? JSONDecoder().decode(ProfileShareData.self, from: data)),
              let mediaId  = profileData.avatarMediaId,
              let mediaUrl = profileData.avatarMediaUrl,
              let mediaKey = profileData.avatarMediaKey else {
            Log.debug("AvatarRetry: profile for \(userId.prefix(8))… has no avatar metadata", category: "AvatarRetry")
            return
        }

        Log.info("AvatarRetry: retrying avatar download for \(userId.prefix(8))… mediaId=\(mediaId.prefix(8))", category: "AvatarRetry")

        do {
            let avatarData = try await MediaManager.shared.downloadAndDecryptAvatar(
                mediaId: mediaId,
                mediaUrl: mediaUrl,
                mediaKey: mediaKey
            )
            await MainActor.run {
                guard let user = context.object(with: objectID) as? User else { return }
                user.avatarData = avatarData
                context.saveAndLog()
                Log.info("AvatarRetry: avatar saved for \(userId.prefix(8))…", category: "AvatarRetry")
            }
        } catch {
            Log.debug("AvatarRetry: download still failed for \(userId.prefix(8))…: \(error.localizedDescription)", category: "AvatarRetry")
        }
    }

    @MainActor
    private func fetchLatestProfileMessageContent(userId: String, context: NSManagedObjectContext) -> String? {
        let request = Message.fetchRequest()
        // Profile messages are NOT sent by the current user and contain type:"profile" in decryptedContent.
        request.predicate = NSPredicate(
            format: "fromUserId == %@ AND decryptedContent CONTAINS %@",
            userId, "\"type\":\"profile\""
        )
        request.sortDescriptors = [NSSortDescriptor(key: "timestamp", ascending: false)]
        request.fetchLimit = 1
        request.returnsObjectsAsFaults = false

        return (try? context.fetch(request))?.first.map { msg in
            let text = msg.displayText
            return text.isEmpty ? nil : text
        } ?? nil
    }
}
