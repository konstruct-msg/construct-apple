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
            Task {
                do {
                    Log.info("📥 Downloading avatar from Media Upload API: \(avatarMediaId)", category: "ProfileSharingManager")
                    
                    // Use MediaManager for avatar download and decryption
                    let decryptedData = try await MediaManager.shared.downloadAndDecryptAvatar(
                        mediaId: avatarMediaId,
                        mediaUrl: avatarMediaUrl,
                        mediaKeyBase64: avatarMediaKey
                    )
                    
                    await MainActor.run {
                        user.avatarData = decryptedData
                        user.isSharingWithMe = true
                        user.sharedWithMeAt = Date()
                        
                        do {
                            try context.save()
                            Log.info("✅ Avatar downloaded and saved for user \(userId)", category: "ProfileSharingManager")
                        } catch {
                            Log.error("❌ Failed to save avatar: \(error)", category: "ProfileSharingManager")
                        }
                    }
                } catch {
                    Log.error("❌ Failed to download avatar: \(error.localizedDescription)", category: "ProfileSharingManager")
                    // Continue - displayName was already updated
                }
            }
        } else if let avatarBase64 = profileData.avatarData,
                  let avatarData = Data(base64Encoded: avatarBase64) {
            // Old format: base64 data (backward compatibility)
            user.avatarData = avatarData
        }
        
        // Mark as sharing with us
        user.isSharingWithMe = true
        user.sharedWithMeAt = Date()
        
        // Add system message to chat
        addSystemMessageToChat(
            userId: userId,
            displayName: profileData.displayName,
            hasAvatar: profileData.avatarMediaId != nil || profileData.avatarData != nil,
            in: context
        )
        
        do {
            try context.save()
            Log.info("✅ Profile data updated for user \(userId): displayName=\(profileData.displayName)", category: "ProfileSharingManager")
        } catch {
            Log.error("❌ Failed to save profile data: \(error)", category: "ProfileSharingManager")
        }
    }
    
    // MARK: - System Messages
    
    /// Add system message to chat when profile is shared
    /// - Parameters:
    ///   - userId: User ID who shared profile
    ///   - displayName: Display name from profile
    ///   - hasAvatar: Whether profile includes avatar
    ///   - context: Core Data context
    func addSystemMessageToChat(
        userId: String,
        displayName: String,
        hasAvatar: Bool,
        in context: NSManagedObjectContext
    ) {
        // Find or create chat
        let chatFetchRequest = Chat.fetchRequest()
        // Combine with additional predicate
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", userId)
        chatFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])
        
        guard let chat = try? context.fetch(chatFetchRequest).first else {
            Log.error("❌ Chat not found for user \(userId)", category: "ProfileSharingManager")
            return
        }
        
        // Create system message
        let message = Message(context: context)
        message.id = UUID().uuidString
        message.timestamp = Date()
        message.chat = chat
        message.fromUserId = userId
        message.toUserId = SessionManager.shared.currentUserId ?? ""
        message.isSentByMe = false
        message.encryptedContent = ""  // System messages don't need encryption
        
        // Use special prefix to mark as system message
        let icon = hasAvatar ? "📸" : "👤"
        message.decryptedContent = "[SYSTEM]\(icon) \(displayName) shared their profile"
        
        message.deliveryStatus = .delivered
        
        // Update chat's last message
        let systemMessageText = message.decryptedContent?.replacingOccurrences(of: "[SYSTEM]", with: "") ?? ""
        chat.lastMessageText = Chat.formatPreviewText(systemMessageText)
        chat.lastMessageTime = message.timestamp
        
        do {
            try context.save()
            Log.info("✅ Added system message for profile share from \(userId)", category: "ProfileSharingManager")
        } catch {
            Log.error("❌ Failed to save system message: \(error)", category: "ProfileSharingManager")
        }
    }
}
