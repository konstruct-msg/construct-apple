//
//  PublicKeyBundleHandler.swift
//  Construct Messenger
//
//  Created by Maxim Eliseyev on 02.02.2026.
//

import Foundation
import CoreData
// For `RPCError` — `notFound` from the key service is a verdict this file has to act on, not a
// transport detail it can stay ignorant of.
import GRPCCore

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
                // Bundle for an incoming first message → X3DH init, OTPK required.
                let keyBundle = try await KeyServiceClient.shared.getPreKeyBundle(userId: userId, consumeOneTimePrekey: true)
                Log.info("SESSION_STATE[fetch_bundle_success]: userId=\(userId.prefix(8))..., attempt=\(attempt)", category: "SessionInit")
                return keyBundle
            } catch {
                lastError = error
                Log.info("SESSION_STATE[fetch_bundle_failed]: attempt=\(attempt)/\(maxAttempts), error=\(error.localizedDescription)", category: "SessionInit")

                // `notFound` is an answer, not a failure to get one. Retrying asks the same
                // question of a server that has already replied definitively, and because the
                // caller retries per redelivered message the retries never end — which is how one
                // deleted account held a device's stream cursor at 31 July for three weeks.
                if let rpc = error as? RPCError, rpc.code == .notFound {
                    Log.info(
                        "SESSION_STATE[fetch_bundle_not_found]: userId=\(userId.prefix(8))… — server has no such user; not retrying",
                        category: "SessionInit"
                    )
                    VanishedPeerStore.shared.markVanished(userId)
                    throw SessionError.peerNotFound
                }

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
    
    /// Every device of `userId`, most likely first, for a handshake whose sending device the
    /// delivery does not name.
    ///
    /// The server blanks `Envelope.sender_device` on delivery **on purpose** — server-visible
    /// metadata must not carry E2E semantics — so a bundle fetched without a device id names
    /// whichever device the server treats as the account's default. On an account with two devices
    /// that is the wrong bundle for every message the other one sent, and the RESPONDER init then
    /// fails with "All 1 prekey(s) failed. Last error: AEAD decryption failed" on a handshake that
    /// is perfectly well formed. Devices 2026-08-28: all ten bundle fetches for the peer went out
    /// with `deviceId=nil`, and the contact — who has a single device and no multi-device anything
    /// — could not establish a session at all.
    ///
    /// A failed RESPONDER init creates no session and advances no ratchet, so trying the wrong
    /// device costs the attempt and nothing else. This is the same walk `openSenderSync` does over
    /// our own devices, for the same reason, against the other account.
    ///
    /// **Does not consume a one-time pre-key.** A RESPONDER init uses the sender's identity, SPK
    /// and verifying key plus *our own* private OTPK, named by the message; the sender's OTPK is
    /// never touched. `fetchPublicKeyWithRetry` consumed one anyway, once per attempt and once per
    /// retry, which drained the pool of every peer that messaged us first.
    /// The pinned device first, the rest in the order the server gave them.
    ///
    /// The pin is the right answer for every single-device account — nearly all of them — so the
    /// walk ends on its first attempt exactly as the single fetch did, and the extra candidates
    /// cost nothing until an account actually has a second device.
    ///
    /// A move, not a sort: `sorted(by:)` is not stable in Swift, and reordering the devices we are
    /// *not* confident about would make the walk's order differ between runs for no reason.
    nonisolated static func orderedByLikelihood(
        _ bundles: [DeviceBundleData],
        pinnedDeviceId: String?
    ) -> [DeviceBundleData] {
        guard let pinned = pinnedDeviceId, !pinned.isEmpty,
              let index = bundles.firstIndex(where: { $0.deviceId == pinned }) else {
            return bundles
        }
        var ordered = bundles
        ordered.insert(ordered.remove(at: index), at: 0)
        return ordered
    }

    func responderBundleCandidates(userId: String) async throws -> [PublicKeyBundleData] {
        let bundles = try await KeyServiceClient.shared.getPreKeyBundles(
            userId: userId,
            consumeOneTimePrekey: false
        )
        let ordered = Self.orderedByLikelihood(
            bundles, pinnedDeviceId: SessionAddressing.cryptoIdentity(ofUser: userId)
        )
        Log.info(
            "SESSION_STATE[responder_candidates]: userId=\(userId.prefix(8))… devices=\(ordered.count) "
            + "order=\(ordered.map { $0.deviceId.prefix(8) }.joined(separator: ","))",
            category: "SessionInit"
        )
        return ordered.map(\.bundle)
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
    /// - Parameter isLastCandidate: whether a failure here is the final word for this message.
    ///   With devices left to try, a failed init means only "not this one", and the repair paths
    ///   below — which exist for a genuine key desync — must not fire on it.
    func handlePublicKeyBundleForIncomingMessage(
        _ data: PublicKeyBundleData,
        message: ChatMessage,
        isLastCandidate: Bool = true,
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
            
            // 1:1 Chat per User. Recreates silently if the user deleted the chat while
            // the remote still had a valid session and sent a fresh X3DH init.
            // Must NOT send END_SESSION here (that causes an endless reset loop).
            let resolved: Chat.FindOrCreateResult
            do {
                guard let result = try Chat.findOrCreate(
                    forUserId: data.userId,
                    in: context,
                    missingUserPolicy: .createContact,
                    touchLastMessageTimeOnCreate: true
                ) else {
                    Log.error("findOrCreateChat returned nil for \(data.userId.prefix(8))…", category: "PublicKeyBundleHandler")
                    return false
                }
                resolved = result
            } catch {
                Log.error("findOrCreateChat failed for \(data.userId.prefix(8))…: \(error)", category: "PublicKeyBundleHandler")
                return false
            }
            if resolved.created {
                Log.info(
                    "Chat not found for \(data.userId.prefix(8))… — recreating after delete",
                    category: "PublicKeyBundleHandler"
                )
            }
            let chat = resolved.chat

            onSuccess(chat, message, decryptedBytes)
            do {
                try context.saveOrThrow(category: "PublicKeyBundleHandler")
                Log.info("Successfully saved decrypted pending message", category: "PublicKeyBundleHandler")
                // Dedup: mark the handshake message processed so a server redelivery
                // (stream-cursor race after reconnect) never re-triggers session init.
                // The X3DH OTPK is consumed by THIS init — a re-init from the same msg0
                // can only fail with "OTPK not found" and spuriously start the heal path.
                // Marked only after the successful save above: if persisting failed, we
                // WANT the redelivery to retry.
                //
                // One call, not three. This site used to write the orchestrator cache, a second
                // Swift-side cache and Core Data in a row, under a comment claiming the
                // orchestrator cache "persists with the next state save" — it does not
                // (`export_orchestrator_state_cfe` writes an empty `processed_ids` on purpose).
                // There is now one cache and one durable store, and `markProcessed` writes both.
                PersistentACKStore.shared.markProcessed(message.id, senderId: data.userId, in: context)
                return true
            } catch {
                Log.error("Failed to persist decrypted pending message for \(data.userId.prefix(8))…: \(error)", category: "PublicKeyBundleHandler")
                return false
            }
            
        } catch SessionError.notAHandshakeCarrier {
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.info(
                "SESSION_STATE[init_refused_not_handshake]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s — leftover is not an X3DH carrier",
                category: "SessionInit"
            )
            return false

        } catch CryptoError.SessionInitializationFailed(let message) {
            // Log detailed error from Rust core
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("Session initialization failed: \(message)", category: "PublicKeyBundleHandler")
            Log.error("SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=SessionInitializationFailed", category: "SessionInit")
            // OTPK-unreproducible: the sender used a 4-DH one-time-prekey we no longer hold, so
            // this handshake is permanently undecryptable and re-fetching the bundle would hand
            // the sender another OTPK that hits the same state (the deadlock). Flag the peer so
            // the END_SESSION we send asks them to re-init WITHOUT an OTPK (3-DH). The Rust core
            // message is "OTPK id=… not found — sender used 4-DH but we cannot reproduce it".
            if message.contains("cannot reproduce") {
                Log.info("SESSION_STATE[otpk_unreproducible]: \(data.userId.prefix(8))… — will request 3-DH re-init via END_SESSION", category: "SessionInit")
                SessionReinitHintStore.shared.recordResponderOtpkUnreproducible(for: data.userId)
            }
            // Check if our keys match what the server serves — desync would explain AEAD failure
            if isLastCandidate {
                Task { await PreKeyRotationService.shared.verifyAndRepairKeyConsistency() }
            }
            return false
            
        } catch {
            let initDuration = Date().timeIntervalSince(initStartTime)
            Log.error("Failed to initialize receiving session: \(error.localizedDescription)", category: "PublicKeyBundleHandler")
            Log.error("SESSION_STATE[init_receiving_failed]: userId=\(data.userId.prefix(8))..., duration=\(String(format: "%.2f", initDuration))s, error=\(error.localizedDescription)", category: "SessionInit")
            if isLastCandidate {
                Task { await PreKeyRotationService.shared.verifyAndRepairKeyConsistency() }
            }
            return false
        }
    }
}
