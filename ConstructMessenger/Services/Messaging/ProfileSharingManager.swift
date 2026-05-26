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

/// Manages profile sharing between users
@MainActor
class ProfileSharingManager {
    
    // MARK: - Singleton
    
    static let shared = ProfileSharingManager()
    
    private init() {}
    
    // MARK: - Profile Message Parsing
    
    /// Parse profile message from decrypted content
    /// - Parameter content: Decrypted message content (JSON string)
    /// - Returns: ProfileShareData if valid profile message, nil otherwise
    func parseProfileMessage(_ content: String) -> ProfileShareData? {
        guard let data = content.data(using: .utf8) else {
            Log.debug("❌ parseProfileMessage: Failed to convert content to data", category: "ProfileSharingManager")
            return nil
        }
        
        // Debug: Log the content being parsed
        Log.debug("📥 Attempting to parse profile message, content length: \(content.count)", category: "ProfileSharingManager")
        Log.debug("   Content preview: \(content.prefix(200))", category: "ProfileSharingManager")
        
        // First, try to parse as generic JSON to check if it looks like a profile message
        if let jsonDict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let type = jsonDict["type"] as? String,
           type == "profile" {
            // It's a profile message, try to decode it properly
            do {
                let json = try JSONDecoder().decode(ProfileShareData.self, from: data)
                Log.info("✅ Successfully parsed profile message: displayName=\(json.displayName), avatarMediaId=\(json.avatarMediaId ?? "nil"), avatarData=\(json.avatarData != nil ? "present" : "nil")", category: "ProfileSharingManager")
                return json
            } catch {
                Log.error("❌ parseProfileMessage: Failed to decode ProfileShareData: \(error)", category: "ProfileSharingManager")
                // Even if decoding fails, we know it's a profile message, so return nil to prevent it from being saved as regular message
                return nil
            }
        }
        
        // Not a profile message
        Log.debug("❌ parseProfileMessage: Content is not a profile message", category: "ProfileSharingManager")
        return nil
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
            Log.error("❌ User not found for profile update: \(userId)", category: "ProfileSharingManager")
            return
        }
        
        // Update user's display name
        user.displayName = profileData.displayName
        
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
            Task {
                do {
                    Log.info("📥 Downloading avatar from Media Upload API: \(avatarMediaId)", category: "ProfileSharingManager")

                    let decryptedData = try await MediaManager.shared.downloadAndDecryptAvatar(
                        mediaId: avatarMediaId,
                        mediaUrl: avatarMediaUrl,
                        mediaKey: avatarMediaKey
                    )

                    await MainActor.run {
                        let viewContext = PersistenceController.shared.container.viewContext
                        guard let liveUser = viewContext.object(with: userObjectID) as? User else { return }
                        liveUser.avatarData = decryptedData
                        liveUser.isSharingWithMe = true
                        liveUser.sharedWithMeAt = Date()

                        do {
                            try viewContext.save()
                            Log.info("✅ Avatar downloaded and saved for user \(userId)", category: "ProfileSharingManager")
                        } catch {
                            Log.error("❌ Failed to save avatar: \(error)", category: "ProfileSharingManager")
                        }
                    }
                } catch {
                    Log.error("❌ Failed to download avatar: \(error.localizedDescription)", category: "ProfileSharingManager")
                }
            }
        } else if let avatarBase64 = profileData.avatarData,
                  let avatarData = Data(base64Encoded: avatarBase64) {
            // Old format: base64 data (backward compatibility)
            user.avatarData = avatarData
        }
        
        // Mark as sharing with us — for async avatar download, isSharingWithMe is set inside the Task
        if profileData.avatarMediaId == nil {
            user.isSharingWithMe = true
            user.sharedWithMeAt = Date()
        }
        
        do {
            try context.save()
            Log.info("✅ Profile data updated for user \(userId): displayName=\(profileData.displayName)", category: "ProfileSharingManager")
        } catch {
            Log.error("❌ Failed to save profile data: \(error)", category: "ProfileSharingManager")
        }
    }
    
}
