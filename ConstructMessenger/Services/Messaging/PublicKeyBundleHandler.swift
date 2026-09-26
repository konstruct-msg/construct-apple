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
        var attempt = 0
        var throttledWaits = 0

        while attempt < maxAttempts {
            attempt += 1
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

                // The mirror of the case above: `resourceExhausted` is a refusal to answer *now*,
                // where `notFound` is a definitive answer. Neither is a transport failure, and the
                // 1s/2s ladder is wrong for both — there it asks a settled question again, here it
                // spends every attempt inside the limiter's own 60s window. Same policy as
                // `SessionInitializationService`, called rather than restated, because two ladders
                // that must agree about one server's limiter is exactly one carrier too many.
                if SessionInitializationService.isRateLimited(error) {
                    guard throttledWaits < SessionInitializationService.maxThrottledWaits else {
                        Log.error("SESSION_STATE[fetch_bundle_throttled_out]: userId=\(userId.prefix(8))… — still rate-limited after \(throttledWaits) window wait(s)", category: "SessionInit")
                        break
                    }
                    throttledWaits += 1
                    attempt -= 1
                    Log.info("SESSION_STATE[fetch_bundle_throttled]: userId=\(userId.prefix(8))… — waiting \(Int(SessionInitializationService.throttleWindowWait))s for the limiter window (wait \(throttledWaits)/\(SessionInitializationService.maxThrottledWaits))", category: "SessionInit")
                    try? await Task.sleep(nanoseconds: UInt64(SessionInitializationService.throttleWindowWait * 1_000_000_000))
                    continue
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
    ///
    /// **The device the carrier names goes before the pinned one.** A sealed delivery carries
    /// its sending device in the certificate (`ResolvedSender.senderDeviceId`), and that is a
    /// stronger answer than the pin: the pin says which device we have talked to before, the
    /// certificate says which device wrote this. Trying the pinned device first on a handshake
    /// from the sibling is not free either — `initReceivingSession` archives an existing
    /// session with a candidate before trying it, so on the stand (2026-09-21 19:25:13) a
    /// re-init from B walked A first, put away C's healthy ratchet with A, then failed on it.
    /// Unnamed (an unsealed carrier, or an unvouched certificate that named nothing) falls back
    /// to the pin as before.
    nonisolated static func orderedByLikelihood(
        _ bundles: [DeviceBundleData],
        pinnedDeviceId: String?,
        namedDeviceId: String? = nil
    ) -> [DeviceBundleData] {
        var ordered = bundles
        // Pinned first, then the named device moved ahead of it — so the order is
        // named, pinned, the rest as the server gave them.
        for preferred in [pinnedDeviceId, namedDeviceId] {
            guard let preferred, !preferred.isEmpty,
                  let index = ordered.firstIndex(where: { $0.deviceId == preferred }) else { continue }
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        return ordered
    }

    /// `namedDevice` is the sending device the carrier's certificate named, when it did.
    func responderBundleCandidates(userId: String, namedDevice: String? = nil) async throws -> [PublicKeyBundleData] {
        let bundles = try await KeyServiceClient.shared.getPreKeyBundles(
            userId: userId,
            consumeOneTimePrekey: false
        )
        let ordered = Self.orderedByLikelihood(
            bundles,
            pinnedDeviceId: SessionAddressing.cryptoIdentity(ofUser: userId),
            namedDeviceId: namedDevice
        )
        Log.info(
            "SESSION_STATE[responder_candidates]: userId=\(userId.prefix(8))… devices=\(ordered.count) "
            + "named=\(namedDevice.map { String($0.prefix(8)) } ?? "—") "
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

}
