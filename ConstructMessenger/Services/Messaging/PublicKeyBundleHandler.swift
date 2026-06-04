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
    
    /// Called when incoming message is successfully decrypted and needs to be saved.
    /// Carries raw decrypted bytes — callers must decode via `ChunkedMessageReassembler.process(data:)`.
    var onMessageDecrypted: ((Chat, ChatMessage, Data) -> Void)?
    
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
                Log.info("SESSION_STATE[fetch_bundle_attempt_\(attempt)]: userId=\(userId.prefix(8))..., maxAttempts=\(maxAttempts)", category: "SessionInit")
                let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId)
                Log.info("SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., attempt=\(attempt)", category: "SessionInit")
                return keyBundle
            } catch {
                lastError = error
                Log.info("SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error.localizedDescription)", category: "SessionInit")
                
                if attempt < maxAttempts {
                    Log.info("⏳ Retrying public key fetch in \(delay)s...", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    delay *= 2  // Exponential backoff: 1s, 2s, 4s
                }
            }
        }
        
        Log.error("SESSION_STATE[fetch_bundle_exhausted]: userId=\(userId.prefix(8))..., allAttemptsFailed", category: "SessionInit")
        throw lastError ?? NetworkError.connectionFailed
    }
    
    /// Handle public key bundle without pending message
    func handlePublicKeyBundle(_ data: PublicKeyBundleData) -> Bool {
        Log.debug("PublicKeyBundleHandler: Received publicKeyBundle for userId: \(data.userId)", category: "PublicKeyBundleHandler")
        return false
    }
    
    /// Handle public key bundle for incoming first message.
    /// - Parameters:
    ///   - data: Public key bundle data
    ///   - message: The encrypted first message
    ///   - onSuccess: Called with raw decrypted bytes when session init succeeds. Caller decodes via `ChunkedMessageReassembler.process(data:)`.
    /// - Returns: True if session was initialized and message decrypted successfully
    func handlePublicKeyBundleForIncomingMessage(
        _ data: PublicKeyBundleData,
        message: ChatMessage,
        onSuccess: @escaping (Chat, ChatMessage, Data) -> Void
    ) -> Bool {
        guard let context = viewContext else {
            Log.error("PublicKeyBundleHandler: No viewContext available", category: "PublicKeyBundleHandler")
            return false
        }
        
        Log.info("Received publicKeyBundle for incoming message from userId: \(data.userId)", category: "PublicKeyBundleHandler")
        
        // Update username if we have the user in Core Data
        let userFetchRequest = User.fetchRequest()
        let userIdPredicate = NSPredicate(format: "id == %@", data.userId)
        var predicates: [NSPredicate] = [userIdPredicate]
        if let existingPredicate = userFetchRequest.predicate {
            predicates.insert(existingPredicate, at: 0)
        }
        userFetchRequest.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        
        if let user = try? context.fetch(userFetchRequest).first {
            // Username comes from invite payload or profile sharing — do not overwrite from bundle.
            _ = user
            Log.debug("PublicKeyBundleHandler: user found for \(data.userId.prefix(8))…", category: "PublicKeyBundleHandler")
        }
        
        // Track prekey ID and detect reinstall
        // trackPreKeyId uses base64 as stable string key for change detection/storage
        let prekeyChanged = CryptoManager.shared.trackPreKeyId(data.signedPrekeyPublic.base64EncodedString(), for: data.userId)
        if prekeyChanged {
            Log.info("Prekey changed for \(data.userId) - potential reinstall detected!", category: "PublicKeyBundleHandler")
            // Session was already archived by trackPreKeyId()
        }
        
        // Initialize receiving session (we are the recipient)
        let initStartTime = Date()
        Log.info("SESSION_STATE[init_receiving_start]: userId=\(data.userId.prefix(8))..., prekeyChanged=\(prekeyChanged)", category: "SessionInit")
        
        do {
            let bundleWithSuite = (
                identityPublic: data.identityPublic,
                signedPrekeyPublic: data.signedPrekeyPublic,
                signature: data.signature,
                verifyingKey: data.verifyingKey,
                suiteId: String(data.suiteId)
            )
            
            // For incoming messages, we are the RECIPIENT.
            // initReceivingSession now returns raw decrypted bytes; decoding happens in saveMessage.
            let decryptedBytes = try CryptoManager.shared.initReceivingSession(
                for: data.userId,
                recipientBundle: bundleWithSuite,
                firstMessage: message,
                spkUploadedAt: data.spkUploadedAt,
                spkRotationEpoch: data.spkRotationEpoch,
                kyberSpkUploadedAt: data.kyberSpkUploadedAt,
                kyberSpkRotationEpoch: data.kyberSpkRotationEpoch
            )
            
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.info("Receiving session initialized for \(data.userId), message decrypted", category: "PublicKeyBundleHandler")
            Log.info("SESSION_STATE[init_receiving_success]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s", category: "SessionInit")
            
            // Find chat for this user; recreate it if the user deleted it locally while
            // the remote side still had a valid session and sent a fresh X3DH init.
            let chatFetchRequest = Chat.fetchRequest()
            chatFetchRequest.predicate = NSPredicate(format: "otherUser.id == %@", data.userId)

            let chat: Chat
            if let existing = try? context.fetch(chatFetchRequest).first {
                chat = existing
            } else {
                // Chat was deleted locally but crypto succeeded — recreate it silently.
                // The user deleted the chat on their side; the remote party initiated a new
                // valid session. We must NOT send END_SESSION here (that causes an
                // endless reset loop). Just re-open the conversation.
                Log.info("Chat not found for \(data.userId.prefix(8))… — recreating after delete", category: "PublicKeyBundleHandler")
                let userFetchRequest = User.fetchRequest()
                userFetchRequest.predicate = NSPredicate(format: "id == %@", data.userId)
                let user: User
                if let existingUser = try? context.fetch(userFetchRequest).first {
                    user = existingUser
                } else {
                    user = User(context: context)
                    user.id = data.userId
                }
                let newChat = Chat(context: context)
                newChat.id = UUID().uuidString
                newChat.otherUser = user
                newChat.lastMessageTime = Date()
                chat = newChat
            }

            onSuccess(chat, message, decryptedBytes)
            do {
                try context.saveOrThrow(category: "PublicKeyBundleHandler")
                Log.info("Successfully saved decrypted pending message", category: "PublicKeyBundleHandler")
                return true
            } catch {
                Log.error("Failed to persist decrypted pending message for \(data.userId.prefix(8))…: \(error)", category: "PublicKeyBundleHandler")
                return false
            }
            
        } catch CryptoError.SessionInitializationFailed(let message) {
            // Log detailed error from Rust core
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("Session initialization failed: \(message)", category: "PublicKeyBundleHandler")
            Log.error("SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=SessionInitializationFailed", category: "SessionInit")
            // Check if our keys match what the server serves — desync would explain AEAD failure
            Task { await PreKeyRotationService.shared.verifyAndRepairKeyConsistency() }
            return false
            
        } catch {
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("Failed to initialize receiving session: \(error.localizedDescription)", category: "PublicKeyBundleHandler")
            Log.error("SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=\(error.localizedDescription)", category: "SessionInit")
            Task { await PreKeyRotationService.shared.verifyAndRepairKeyConsistency() }
            return false
        }
    }
}
