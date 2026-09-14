//
//  ChatSessionManager.swift
//  Construct Messenger
//

import Foundation
import CoreData

@MainActor
final class ChatSessionManager {

    // MARK: - Dependencies

    private let chat: Chat
    private let sessionInitService: SessionInitializationService
    private weak var viewModel: ChatViewModel?

    // MARK: - State

    private var recipientBundle: (identityPublic: Data, signedPrekeyPublic: Data, signature: Data, verifyingKey: Data)?
    private var publicKeyFetchTimer: Timer?
    private let publicKeyFetchTimeout: TimeInterval = 10.0

    var cachedIdentityKey: Data? { recipientBundle?.identityPublic }

    // MARK: - Callbacks (userId, reason-string)

    var onSessionReady: ((String) -> Void)?
    var onSessionFailed: ((String, String) -> Void)?

    // MARK: - Init

    init(chat: Chat) {
        self.chat = chat
        self.sessionInitService = SessionInitializationService.shared
    }

    func setViewModel(_ vm: ChatViewModel) {
        self.viewModel = vm
    }

    // MARK: - Session readiness

    func checkExistingSession() {
        guard let userId = chat.otherUser?.id else { return }
        let ready = CryptoManager.shared.hasSession(for: userId)
        viewModel?.isSessionReady = ready
        if ready {
            Log.info("Session already exists for user: \(userId)", category: "ChatViewModel")
        } else {
            Log.debug("No session yet for user: \(userId)", category: "ChatViewModel")
        }
    }

    func fetchRecipientPublicKey() {
        guard let userId = chat.otherUser?.id else {
            Log.error("Cannot fetch recipient public key: chat.otherUser?.id is nil", category: "ChatViewModel")
            return
        }
        guard let currentUserId = AuthSessionManager.shared.currentUserId else {
            Log.error("Cannot fetch recipient public key: currentUserId is nil", category: "ChatViewModel")
            return
        }
        Log.debug("Fetching public key for userId: \(userId), currentUserId: \(currentUserId)", category: "ChatViewModel")
        if userId == currentUserId {
            ErrorRouter.shared.report(.validation(.selfSend))
            Log.debug("Blocked attempt to initialize session with self", category: "ChatViewModel")
            return
        }
        // Whether this fetch is allowed to burn one of the peer's one-time pre-keys.
        //
        // `getPreKeyBundle` is destructive: the server DELETEs an OTPK and hands it out.
        // `onViewAppear` calls this on every chat open, so an unnecessary consuming fetch
        // drains a real contact's pool — device logs showed 10 fetches in 5.5 minutes, every
        // one landing on "session already established". That is what emptied the peer's pool
        // and left new inbound sessions running X3DH with no one-time pre-key.
        //
        // The old guard was `isSessionReady == true && hasUsername`, which conflated key
        // material with a *profile* concern: a contact whose username we never stored slipped
        // through on every open, and since a key bundle carries no username the condition
        // could never become true — a permanent loop. Ask the crypto core instead
        // (authoritative; `isSessionReady` is per-ViewModel view state that resets on each
        // chat open) and leave username backfill to the profile path, which owns it.
        let sessionExists = CryptoManager.shared.hasSession(for: userId)
        if sessionExists {
            viewModel?.isSessionReady = true
            // Skip the network entirely only when the identity key is already available —
            // stealth sealing needs it, and under stealth-on a missing key is fail-closed
            // (`StealthDowngradeBlocked` → queue + retry), so silently skipping would stall
            // sends for a contact we only ever responded to. Otherwise fall through to a
            // NON-consuming fetch: same long-lived material, no OTPK burned.
            if recipientBundle != nil || StealthSenderService.recipientIdentityKey(
                recipientId: userId,
                context: PersistenceController.shared.container.viewContext
            ) != nil {
                return
            }
            Log.debug("Session exists but no cached identity key for \(userId.prefix(8))… — non-consuming bundle fetch", category: "ChatViewModel")
        }

        publicKeyFetchTimer?.invalidate()
        publicKeyFetchTimer = Timer.scheduledTimer(withTimeInterval: publicKeyFetchTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.viewModel?.isSessionReady == false else { return }
                Log.error("Timeout waiting for public key bundle from server", category: "ChatViewModel")
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })
                self.viewModel?.isSessionReady = false
            }
        }

        Task { [weak self] in
            guard let self else { return }
            do {
                let publicKeyBundle = try await sessionInitService.fetchPublicKeyWithRetry(
                    userId: userId,
                    consumeOneTimePrekey: !sessionExists
                )
                publicKeyFetchTimer?.invalidate()
                publicKeyFetchTimer = nil
                handlePublicKeyBundle(publicKeyBundle)
            } catch {
                publicKeyFetchTimer?.invalidate()
                publicKeyFetchTimer = nil
                Log.error("Failed to fetch public key via gRPC after retries: \(error.localizedDescription)", category: "ChatViewModel")
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })
                viewModel?.isSessionReady = false
            }
        }
    }

    private func handlePublicKeyBundle(_ data: PublicKeyBundleData) {
        Log.debug("Received publicKeyBundle for userId: \(data.userId), chat.otherUser?.id: \(chat.otherUser?.id ?? "nil"), match: \(data.userId == chat.otherUser?.id)", category: "ChatViewModel")
        guard data.userId == chat.otherUser?.id else { return }
        self.recipientBundle = (data.identityPublic, data.signedPrekeyPublic, data.signature, data.verifyingKey)
        publicKeyFetchTimer?.invalidate()
        publicKeyFetchTimer = nil
        viewModel?.isSessionReady = true
        if CryptoManager.shared.hasSession(for: data.userId) {
            Log.info("SESSION_STATE[bundle_fetched_session_exists]: session already established for \(data.userId.prefix(8))…", category: "ChatViewModel")
        } else {
            Log.info("SESSION_STATE[bundle_cached]: bundle ready for \(data.userId.prefix(8))…, session will be created on first send", category: "ChatViewModel")
        }
        onSessionReady?(data.userId)
    }

    func initializeSessionProactively(userId: String) async {
        viewModel?.isInitializingSession = true
        await sessionInitService.initializeSessionProactively(
            userId: userId,
            // Reached from opening a conversation and from sending into one; both are a person
            // waiting on this session, which is what the flag means.
            hasOutboundWork: true,
            onSuccess: { [weak self] in
                guard let self else { return }
                self.viewModel?.isSessionReady = true
                self.viewModel?.isInitializingSession = false
                Task { [weak self] in
                    guard let self else { return }
                    await self.sendSessionInitPing(to: userId)
                    self.onSessionReady?(userId)
                }
            },
            onFailure: { [weak self] error in
                guard let self else { return }
                self.viewModel?.isInitializingSession = false
                if case CryptoManagerError.coreNotInitialized = error {
                    Log.error("coreNotInitialized in initializeSessionProactively — OrchestratorCore missing", category: "ChatViewModel")
                    ErrorRouter.shared.report(error)
                    self.onSessionFailed?(userId, error.userFacingMessage)
                    return
                }
                ErrorRouter.shared.report(.sessionInitFailed(contactId: userId), recovery: { [weak self] in
                    self?.fetchRecipientPublicKey()
                })
                self.onSessionFailed?(userId, error.userFacingMessage)
            }
        )
    }

    /// Post-init ping (msgNum=0) announcing our fresh ratchet to the peer.
    ///
    /// This is the third session-control chokepoint. `f39e03b4` sealed the other two
    /// (`sendSessionControlCore`, `sendEndSession`) and missed this one, so under always-on
    /// stealth it kept emitting an identified `senderId` on every establishment — the exact
    /// sender→recipient+conversation signal the sealed control channel exists to close
    /// (observed 2026-07-31: SRI and session_ready sent as `[STEALTH]`, this ping as a plain
    /// user id in the same instant). Sealed here on the same fail-closed pattern:
    /// no recipient identity key / seal failure ⇒ the ping is skipped, never downgraded.
    /// Skipping is safe — the ping is an optimisation, and the peer still establishes from
    /// the X3DH carrier plus the tie-break watchdog.
    func sendSessionInitPing(to userId: String) async {
        guard CryptoManager.shared.hasSession(for: userId) else { return }
        // A SESSION_RESET_INIT is in flight for this peer and owns msgNum=0 on the (now shared,
        // post-coalescing) session. The ping exists only to keep msgNum=0 off user content, so
        // once the SRI has that slot it is redundant — and sending it would put a second X3DH
        // carrier on the wire that the peer can only discard.
        guard !SessionConfirmationTracker.shared.isPending(userId) else {
            Log.info("SESSION_STATE[init_ping_skipped]: SESSION_RESET_INIT owns msgNum=0 for \(userId.prefix(8))…", category: "SessionInit")
            return
        }
        guard let myId = AuthSessionManager.shared.currentUserId, !myId.isEmpty else { return }
        let pingId = UUID().uuidString.lowercased()
        let nonce = UUID().uuidString
        // The ping's type rides in KNST byte 5, inside the ciphertext; the server is told nothing.
        // Outer envelope only — the sealed path declares `.generic` (see `SealedEnvelopeType`).
        let contentType: Shared_Proto_Core_V1_ContentType = .unspecified
        let conversationId = ConversationId.direct(myUserId: myId, theirUserId: userId)
        let timestamp = UInt64(Date().timeIntervalSince1970)
        do {
            let payload = try OutboundSessionService.shared.encryptSessionControl(
                payload: SessionControlCodec.encodePayload(op: .ping, nonce: nonce),
                messageId: pingId,
                recipientId: userId,
                frameAs: SessionControlCodec.frameContentType(for: .ping)
            )

            if StealthPolicy.shared.shouldUseSealedSender() {
                let ctx = chat.managedObjectContext ?? PersistenceController.shared.container.viewContext
                guard let recipientIK = StealthSenderService.recipientIdentityKey(recipientId: userId, context: ctx) else {
                    throw StealthDowngradeBlocked(reason: "no recipient identity key for init ping → \(userId.prefix(8))…")
                }
                let sealedInner = try await StealthSenderService.buildSealedInner(
                    recipientUserId: userId,
                    recipientIdentityKey: recipientIK,
                    encryptedPayload: payload,
                    contentType: .generic
                )
                _ = try await StealthSendRecovery.sendSealed(sealedInner, rebuild: {
                    try await StealthSenderService.buildSealedInner(
                        recipientUserId: userId,
                        recipientIdentityKey: recipientIK,
                        encryptedPayload: payload,
                        contentType: .generic
                    )
                }, send: { inner in
                    try await MessagingServiceClient.shared.sendMessage(
                        messageId: pingId,
                        recipientId: userId,
                        senderId: myId,
                        conversationId: conversationId,
                        encryptedPayload: payload,
                        timestamp: timestamp,
                        sealing: .sealed(inner)
                    )
                })
            } else {
                _ = try await MessagingServiceClient.shared.sendMessage(
                    messageId: pingId,
                    recipientId: userId,
                    senderId: myId,
                    conversationId: conversationId,
                    encryptedPayload: payload,
                    timestamp: timestamp,
                    contentType: contentType,
                    sealing: .identified(.stealthDisabled)
                )
            }
            Log.info("SESSION_STATE[init_ping_sent]: msgNum=0 ping sent to \(userId.prefix(8))… — user messages follow as msgNum=1+", category: "SessionInit")
        } catch let blocked as StealthDowngradeBlocked {
            Log.error("SESSION_STATE[init_ping_downgrade_blocked]: \(blocked.reason) — ping skipped (never sent identified under stealth)", category: "SessionInit")
        } catch {
            Log.error("SESSION_STATE[init_ping_failed]: \(error.localizedDescription) for \(userId.prefix(8))… — user messages will be sent anyway", category: "SessionInit")
        }
    }
}
