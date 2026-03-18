//
//  PublicKeyBundleHandler.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 02.02.2026.
//

import Foundation
import CoreData

/// Handles public key bundle fetching, retry logic, and session initialization
/// Extracted from ChatsViewModel Phase 1.5
@MainActor
class PublicKeyBundleHandler {
    
    // MARK: - Callbacks
    
    /// Called when username needs to be updated
    var onUsernameUpdate: ((String, String) -> Void)?
    
    /// Called when incoming message is successfully decrypted and needs to be saved
    var onMessageDecrypted: ((Chat, ChatMessage, String) -> Void)?
    
    // MARK: - Core Data
    
    private var viewContext: NSManagedObjectContext?
    
    func setContext(_ context: NSManagedObjectContext) {
        self.viewContext = context
    }
    
    // MARK: - Public Key Fetching
    
    /// Fetch public key bundle with retry and exponential backoff
    /// - Parameters:
    ///   - userId: Target user ID
    ///   - maxAttempts: Maximum retry attempts (default: 3)
    ///   - initialDelay: Initial retry delay in seconds (default: 1.0)
    /// - Returns: Public key bundle data
    /// - Throws: Last error if all attempts fail
    func fetchPublicKeyWithRetry(
        userId: String,
        maxAttempts: Int = 3,
        initialDelay: TimeInterval = 1.0
    ) async throws -> PublicKeyBundleData {
        var lastError: Error?
        var delay = initialDelay
        
        for attempt in 1...maxAttempts {
            do {
                Log.info("🔑 SESSION_STATE[fetch_bundle_attempt_\(attempt)]: userId=\(userId.prefix(8))..., maxAttempts=\(maxAttempts)", category: "SessionInit")
                let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId)
                Log.info("✅ SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., attempt=\(attempt)", category: "SessionInit")
                return keyBundle
            } catch {
                lastError = error
                Log.info("⚠️ SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error.localizedDescription)", category: "SessionInit")
                
                if attempt < maxAttempts {
                    Log.info("⏳ Retrying public key fetch in \(delay)s...", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2  // Exponential backoff: 1s, 2s, 4s
                }
            }
        }
        
        Log.error("❌ SESSION_STATE[fetch_bundle_exhausted]: userId=\(userId.prefix(8))..., allAttemptsFailed", category: "SessionInit")
        throw lastError ?? NetworkError.connectionFailed
    }
    
    // MARK: - Bundle Handling
    
    /// Handle public key bundle without pending message (username update)
    /// - Parameters:
    ///   - data: Public key bundle data
    /// - Returns: True if username was updated
    func handlePublicKeyBundle(_ data: PublicKeyBundleData) -> Bool {
        Log.debug("📦 PublicKeyBundleHandler: Received publicKeyBundle for userId: \(data.userId)", category: "PublicKeyBundleHandler")
        
        guard let context = viewContext else { 
            Log.error("❌ PublicKeyBundleHandler: No viewContext available", category: "PublicKeyBundleHandler")
            return false 
        }
        
        // Find user in any chat
        let chatFetch = Chat.fetchRequest()
        let otherUserPredicate = NSPredicate(format: "otherUser.id == %@", data.userId)
        chatFetch.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: [otherUserPredicate])
        
        if let existingChat = try? context.fetch(chatFetch).first,
           let user = existingChat.otherUser {
            let oldUsername = user.username
            user.username = data.username
            // Preserve profile-shared name; server username may be empty/UUID
            if !data.username.isEmpty, UUID(uuidString: data.username) == nil, data.username.lowercased() != "anonymous" {
                user.displayName = data.username
            } else if !user.isSharingWithMe {
                user.displayName = DisplayNameGenerator.generate(from: data.userId)
            }
            do {
                try context.save()
                Log.info("✅ Updated username: \(oldUsername) → \(data.username)", category: "PublicKeyBundleHandler")
                
                // Notify via callback
                onUsernameUpdate?(data.userId, data.username)
                return true
            } catch {
                Log.error("❌ Failed to save username update: \(error.localizedDescription)", category: "PublicKeyBundleHandler")
                return false
            }
        }
        
        Log.debug("ℹ️ No existing chat found for userId: \(data.userId)", category: "PublicKeyBundleHandler")
        return false
    }
    
    /// Handle public key bundle for incoming first message
    /// - Parameters:
    ///   - data: Public key bundle data
    ///   - message: The encrypted first message
    ///   - onSuccess: Called when message is decrypted and ready to save (chat, message, decryptedContent)
    /// - Returns: True if session was initialized and message decrypted successfully
    func handlePublicKeyBundleForIncomingMessage(
        _ data: PublicKeyBundleData,
        message: ChatMessage,
        onSuccess: @escaping (Chat, ChatMessage, String) -> Void
    ) -> Bool {
        guard let context = viewContext else {
            Log.error("❌ PublicKeyBundleHandler: No viewContext available", category: "PublicKeyBundleHandler")
            return false
        }
        
        Log.info("📦 Received publicKeyBundle for incoming message from userId: \(data.userId)", category: "PublicKeyBundleHandler")
        
        // Update username if we have the user in Core Data
        let userFetchRequest = User.fetchRequest()
        let userIdPredicate = NSPredicate(format: "id == %@", data.userId)
        var predicates: [NSPredicate] = [userIdPredicate]
        if let existingPredicate = userFetchRequest.predicate {
            predicates.insert(existingPredicate, at: 0)
        }
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        
        if let user = try? context.fetch(userFetchRequest).first {
            let normalized = data.username.trimmingCharacters(in: .whitespacesAndNewlines)
            if !normalized.isEmpty, normalized.lowercased() != "anonymous", UUID(uuidString: normalized) == nil {
                user.username = normalized
                user.displayName = normalized
            } else {
                user.username = ""
                // Preserve profile-shared name if the contact shared their profile with us
                if !user.isSharingWithMe {
                    user.displayName = DisplayNameGenerator.generate(from: data.userId)
                }
            }
            context.saveAndLog()
            Log.info("Updated username for user: \(data.username)", category: "PublicKeyBundleHandler")
        }
        
        // Track prekey ID and detect reinstall
        let prekeyChanged = CryptoManager.shared.trackPreKeyId(data.signedPrekeyPublic, for: data.userId)
        if prekeyChanged {
            Log.info("⚠️ Prekey changed for \(data.userId) - potential reinstall detected!", category: "PublicKeyBundleHandler")
            // Session was already archived by trackPreKeyId()
        }
        
        // Initialize receiving session (we are the recipient)
        let initStartTime = Date()
        Log.info("🔐 SESSION_STATE[init_receiving_start]: userId=\(data.userId.prefix(8))..., prekeyChanged=\(prekeyChanged)", category: "SessionInit")
        
        do {
            let bundleWithSuite = (
                identityPublic: data.identityPublic,
                signedPrekeyPublic: data.signedPrekeyPublic,
                signature: data.signature,
                verifyingKey: data.verifyingKey,
                suiteId: "1"
            )
            
            // For incoming messages, we are the RECIPIENT
            // Use initReceivingSession which takes the first message and returns decrypted content
            let decryptedContent = try CryptoManager.shared.initReceivingSession(
                for: data.userId,
                recipientBundle: bundleWithSuite,
                firstMessage: message
            )
            
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.info("✅ Receiving session initialized for \(data.userId), message decrypted", category: "PublicKeyBundleHandler")
            Log.info("🔐 SESSION_STATE[init_receiving_success]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s", category: "SessionInit")
            
            // Find chat for this user
            let chatFetchRequest = Chat.fetchRequest()
            chatFetchRequest.predicate = NSPredicate(format: "otherUser.id == %@", data.userId)
            
            if let chat = try? context.fetch(chatFetchRequest).first {
                // Call success callback with the decrypted data
                onSuccess(chat, message, decryptedContent)
                // Note: chat.lastMessageText is updated by onSuccess (saveMessage) with correct plaintext
                context.saveAndLog()
                Log.info("✅ Successfully saved decrypted pending message", category: "PublicKeyBundleHandler")
                return true
            } else {
                Log.error("❌ Chat not found for userId: \(data.userId)", category: "PublicKeyBundleHandler")
                return false
            }
            
        } catch CryptoError.SessionInitializationFailed(let message) {
            // Log detailed error from Rust core
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("❌ Session initialization failed: \(message)", category: "PublicKeyBundleHandler")
            Log.error("🔐 SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=SessionInitializationFailed", category: "SessionInit")
            return false
            
        } catch {
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("❌ Failed to initialize receiving session: \(error.localizedDescription)", category: "PublicKeyBundleHandler")
            Log.error("🔐 SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=\(error.localizedDescription)", category: "SessionInit")
            return false
        }
    }
}
