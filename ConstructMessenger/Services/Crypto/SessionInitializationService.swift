import Foundation
import os.log

/// Service responsible for session initialization with retry logic and queue management
@MainActor
class SessionInitializationService {
    
    // MARK: - Public Methods
    
    /// Fetch public key bundle with exponential backoff retry
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
                if #available(iOS 18.0, *) {
                    let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId)
                    Log.info("✅ SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., attempt=\(attempt)", category: "SessionInit")
                    return keyBundle
                } else {
                    throw NetworkError.connectionFailed
                }
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
    
    /// Initialize a session with a recipient using their public key bundle
    func initializeSession(
        userId: String,
        bundle: PublicKeyBundleData,
        deleteExisting: Bool = true
    ) throws {
        // Proactively delete stale session if requested
        if deleteExisting {
            if CryptoManager.shared.hasSession(for: userId) {
                CryptoManager.shared.archiveSession(for: userId, reason: .manualReset)
                Log.info("🗑️ Proactively deleted any existing session for \(userId) before initialization.", category: "SessionInit")
            }
        }
        
        let bundleWithSuite = (
            identityPublic: bundle.identityPublic,
            signedPrekeyPublic: bundle.signedPrekeyPublic,
            signature: bundle.signature,
            verifyingKey: bundle.verifyingKey,
            suiteId: String(bundle.suiteId)
        )
        
        do {
            try CryptoManager.shared.initializeSession(for: userId, recipientBundle: bundleWithSuite)
        } catch {
            Log.error("❌ Session init failed for \(userId): \(error)", category: "SessionInit")
            Log.error("   bundle.suiteId=\(bundle.suiteId), identityPublic.len=\(bundle.identityPublic.count), signedPrekeyPublic.len=\(bundle.signedPrekeyPublic.count)", category: "SessionInit")
            throw error
        }
        Log.info("✅ Session initialized as INITIATOR for \(userId)", category: "SessionInit")
    }
    
    /// Proactively initialize session for a user (fetch bundle + initialize)
    func initializeSessionProactively(
        userId: String,
        onSuccess: @escaping () -> Void,
        onFailure: @escaping (Error) -> Void
    ) async {
        Log.info("🔐 SESSION_STATE[proactive_init_start]: userId=\(userId.prefix(8))...", category: "SessionInit")
        
        do {
            // Fetch bundle with retry
            let bundle = try await fetchPublicKeyWithRetry(userId: userId)
            
            // Initialize sending session
            try initializeSession(userId: userId, bundle: bundle, deleteExisting: true)
            
            Log.info("✅ SESSION_STATE[proactive_init_success]: userId=\(userId.prefix(8))...", category: "SessionInit")
            
            // Notify success on main actor
            await MainActor.run {
                onSuccess()
            }
            
        } catch {
            Log.error("❌ SESSION_STATE[proactive_init_failed]: userId=\(userId.prefix(8))..., error=\(error.localizedDescription)", category: "SessionInit")
            
            // Notify failure on main actor
            await MainActor.run {
                onFailure(error)
            }
        }
    }
}
