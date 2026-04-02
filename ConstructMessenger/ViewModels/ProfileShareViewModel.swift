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

    init() {}

    init(context: NSManagedObjectContext) {
        self.viewContext = context
    }

    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }
    
    /// Share profile (displayName and avatar) with another user via E2E encrypted message
    /// Avatar is uploaded via Media Upload API to avoid size limitations
    func shareProfile(with userId: String, completion: @escaping (Bool, String?) -> Void) {
        guard let context = viewContext,
              let currentUserId = SessionManager.shared.currentUserId else {
            completion(false, NSLocalizedString("not_authenticated", comment: ""))
            return
        }
        
        // Get current user's profile data
        let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
        userFetchRequest.predicate = NSPredicate(format: "id == %@", currentUserId)
        
        guard let currentUser = try? context.fetch(userFetchRequest).first else {
            completion(false, NSLocalizedString("user_not_found", comment: ""))
            return
        }
        
        // Prevent concurrent share attempts
        guard !isSharingProfile else {
            Log.info("⏸️ Profile share already in progress, ignoring duplicate", category: "ProfileShare")
            return
        }
        isSharingProfile = true
        
        // Upload avatar via Media Upload API if available
        Task {
            defer { isSharingProfile = false }

            // Check if session is ready; if not, initialize it on-demand
            if !CryptoManager.shared.hasSession(for: userId) {
                Log.info("🔐 No session for \(userId) — initializing before profile share", category: "ProfileShare")
                let service = SessionInitializationService.shared
                do {
                    let bundle = try await service.fetchPublicKeyWithRetry(userId: userId)
                    try service.initializeSession(userId: userId, bundle: bundle, deleteExisting: false)
                    Log.info("✅ Session initialized for profile share with \(userId)", category: "ProfileShare")
                } catch {
                    Log.error("❌ Failed to initialize session for profile share: \(error)", category: "ProfileShare")
                    await MainActor.run {
                        completion(false, NSLocalizedString("failed_to_establish_session", comment: ""))
                    }
                    return
                }
            }

            var avatarMediaId: String? = nil
            var avatarMediaUrl: String? = nil
            var avatarMediaKey: String? = nil
            var avatarMediaType: String? = nil
            
            if let avatarData = currentUser.avatarData,
               let avatarImage = ImageHelper.imageFromData(avatarData) {
                do {
                    Log.info("📤 Uploading avatar via MediaManager", category: "ProfileShare")
                    let uploadResult = try await MediaManager.shared.uploadAvatar(avatarImage)
                    avatarMediaId = uploadResult.mediaId
                    avatarMediaUrl = uploadResult.mediaUrl
                    avatarMediaKey = uploadResult.encryptionKey
                    avatarMediaType = "image/jpeg"
                    Log.info("✅ Avatar uploaded: \(uploadResult.mediaId)", category: "ProfileShare")
                } catch {
                    Log.error("❌ Failed to upload avatar: \(error.localizedDescription)", category: "ProfileShare")
                }
            }
            
            // Create profile data with media info
            let profileData = ProfileShareData(
                displayName: currentUser.resolvedDisplayName,
                avatarMediaId: avatarMediaId,
                avatarMediaUrl: avatarMediaUrl,
                avatarMediaKey: avatarMediaKey,
                avatarMediaType: avatarMediaType,
                timestamp: Int64(Date().timeIntervalSince1970)
            )
            
            // Serialize to JSON
            guard let jsonData = try? JSONEncoder().encode(profileData),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                await MainActor.run {
                    completion(false, NSLocalizedString("failed_to_encode_profile", comment: ""))
                }
                return
            }
            
            // Check final JSON size (before encryption)
            let jsonSize = jsonString.utf8.count
            Log.debug("📤 Profile data JSON size: \(jsonSize) bytes (before encryption)", category: "ProfileShare")
            Log.debug("   displayName: \(profileData.displayName)", category: "ProfileShare")
            Log.debug("   avatarMediaId: \(avatarMediaId ?? "nil")", category: "ProfileShare")
            Log.debug("   type: \(profileData.type)", category: "ProfileShare")
            
            // Encrypt and send via E2E message
            do {
                Log.debug("🔐 Encrypting profile message for user \(userId), JSON size: \(jsonSize) bytes", category: "ProfileShare")
                let messageId = UUID().uuidString
                let plan = ChunkedMessageSender.shared.buildPlan(plaintext: jsonString, messageId: UUID(uuidString: messageId) ?? UUID())
                let firstPayload = plan.payloads.first ?? jsonString
                let firstComponents = try CryptoManager.shared.encryptMessage(firstPayload, for: userId)

                Log.debug("✅ Profile message encrypted successfully, messageNumber: \(firstComponents.messageNumber)", category: "ProfileShare")

                let message = ChatMessage(
                    id: messageId,
                    from: currentUserId,
                    to: userId,
                    messageType: nil,  // Will be set by server
                    ephemeralPublicKey: firstComponents.ephemeralPublicKey,
                    messageNumber: firstComponents.messageNumber,
                content: firstComponents.content.base64EncodedString(),
                    suiteId: firstComponents.suiteId,
                    timestamp: UInt64(Date().timeIntervalSince1970),
                    oneTimePreKeyId: firstComponents.oneTimePreKeyId
                )

                // ✅ Send via gRPC
                do {
                    let conversationId = ConversationId.direct(myUserId: currentUserId, theirUserId: userId)
                    let responses = try await ChunkedMessageSender.shared.sendChunks(
                        plan: plan,
                        senderId: currentUserId,
                        recipientId: userId,
                        conversationId: conversationId,
                        timestamp: message.timestamp,
                        preEncryptedFirst: firstComponents
                    )
                    let response = responses.first ?? SendMessageResponse(messageId: message.id, status: "sent")
                    if response.status.lowercased() == "blocked" {
                        Log.error("🚫 Profile share rejected — sender is blocked by \(userId.prefix(8))…", category: "ProfileShare")
                        await MainActor.run { completion(false, "blocked") }
                        return
                    }
                    Log.info("✅ Profile shared with user \(userId) via gRPC: \(response.messageId)", category: "ProfileShare")
                    await MainActor.run {
                        completion(true, nil)
                    }
                } catch {
                    Log.error("❌ Failed to send profile message via gRPC: \(error.localizedDescription)", category: "ProfileShare")
                    await MainActor.run {
                        completion(false, error.localizedDescription)
                    }
                    return
                }
            } catch {
                Log.error("❌ Failed to share profile: \(error)", category: "ProfileShare")
                let appError = AppError.from(error)
                await MainActor.run {
                    ErrorRouter.shared.report(appError)
                    completion(false, appError.errorDescription)
                }
            }
        }
    }
    
    /// Handle received profile data from another user
    func handleReceivedProfile(_ profileData: ProfileShareData, from userId: String) {
        guard let context = viewContext else { return }
        
        let userFetchRequest: NSFetchRequest<User> = User.fetchRequest()
        userFetchRequest.predicate = NSPredicate(format: "id == %@", userId)
        
        guard let user = try? context.fetch(userFetchRequest).first else {
            Log.error("❌ User not found for profile update: \(userId)", category: "ProfileShare")
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
                    Log.info("📥 Downloading avatar from Media Upload API: \(avatarMediaId)", category: "ProfileShare")
                    
                    // Decrypt media key from Double Ratchet message
                    // The avatarMediaKey is encrypted with Double Ratchet, so we need to decrypt it
                    // But we don't have the message structure... Let's use a workaround:
                    // Create a temporary message structure to decrypt the key
                    
                    // Actually, for profile sharing, we should decrypt the mediaKey as part of the profile message
                    // But the mediaKey is in the JSON, which is already decrypted...
                    // So the mediaKey should be the raw base64-encoded key, not Double Ratchet encrypted.
                    
                    // Let me check the current implementation... In shareProfile(), we call:
                    // encryptMediaKey() which returns encrypted.content (Double Ratchet encrypted)
                    // But to decrypt it, we need ephemeralPublicKey and messageNumber.
                    
                    // Solution: For profile sharing, we should include the raw media key in the JSON
                    // (the JSON is already E2E encrypted, so it's secure).
                    // Let's update shareProfile() to use the raw key instead of encrypting it again.
                    
                    // The mediaKey is base64-encoded raw key (JSON is already E2E encrypted)
                    let avatarData = try await MediaManager.shared.downloadAndDecryptMedia(
                        mediaId: avatarMediaId,
                        mediaUrl: avatarMediaUrl,
                        mediaKeyBase64: avatarMediaKey
                    )
                    
                    await MainActor.run {
                        user.avatarData = avatarData
                        do {
                            try context.save()
                            Log.info("✅ Avatar downloaded and saved for user \(userId)", category: "ProfileShare")
                        } catch {
                            Log.error("❌ Failed to save avatar: \(error)", category: "ProfileShare")
                        }
                    }
                } catch {
                    Log.error("❌ Failed to download avatar: \(error.localizedDescription)", category: "ProfileShare")
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
        
        do {
            try context.save()
            Log.info("✅ Profile data updated for user \(userId)", category: "ProfileShare")
        } catch {
            Log.error("❌ Failed to save profile data: \(error)", category: "ProfileShare")
        }
    }

    // MARK: - Avatar rebroadcast

    /// Re-send current profile (including updated avatar) to all contacts we are sharing with.
    /// Call this whenever the user changes their avatar or display name so contacts stay in sync.
    /// Uses a background Task per contact — failures are logged but don't surface to the user.
    func rebroadcastProfileToSharedContacts() {
        guard let context = viewContext,
              let currentUserId = SessionManager.shared.currentUserId else { return }

        // Fetch all contacts we have chosen to share our profile with
        let fetchRequest: NSFetchRequest<User> = User.fetchRequest()
        fetchRequest.predicate = NSPredicate(format: "amISharingWith == YES AND id != %@", currentUserId)

        guard let contacts = try? context.fetch(fetchRequest), !contacts.isEmpty else {
            Log.info("📤 No contacts to rebroadcast profile to", category: "ProfileShare")
            return
        }

        let contactIds = contacts.map(\.id)
        Log.info("📤 Rebroadcasting profile to \(contactIds.count) contact(s)", category: "ProfileShare")

        for contactId in contactIds {
            Task {
                await withCheckedContinuation { continuation in
                    shareProfile(with: contactId) { success, error in
                        if success {
                            Log.info("✅ Profile rebroadcast to \(contactId.prefix(8))", category: "ProfileShare")
                        } else {
                            Log.error("⚠️ Profile rebroadcast to \(contactId.prefix(8)) failed: \(error ?? "unknown")", category: "ProfileShare")
                        }
                        continuation.resume()
                    }
                }
            }
        }
    }
}
