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
        let ready = CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId)
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
        let sessionExists = CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: userId)
        if sessionExists {
            viewModel?.isSessionReady = true
            // Skip the network entirely only when the identity key is already available —
            // stealth sealing needs it, and under stealth-on a missing key is fail-closed
            // (`StealthDowngradeBlocked` → queue + retry), so silently skipping would stall
            // sends for a contact we only ever responded to. Otherwise fall through to a
            // NON-consuming fetch: same long-lived material, no OTPK burned.
            if recipientBundle != nil || StealthSenderService.recipientIdentityKey(recipientId: userId) != nil {
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
        if CryptoManager.shared.hasSessionWithAnyDevice(ofPeer: data.userId) {
            Log.info("SESSION_STATE[bundle_fetched_session_exists]: session already established for \(data.userId.prefix(8))…", category: "ChatViewModel")
        } else {
            Log.info("SESSION_STATE[bundle_cached]: bundle ready for \(data.userId.prefix(8))…, session will be created on first send", category: "ChatViewModel")
        }
        onSessionReady?(data.userId)
    }

    func initializeSessionProactively(userId: String) async {
        viewModel?.isInitializingSession = true
        var succeeded = false
        await sessionInitService.initializeSessionProactively(
            userId: userId,
            // Reached from opening a conversation and from sending into one; both are a person
            // waiting on this session, which is what the flag means.
            hasOutboundWork: true,
            onSuccess: { [weak self] in
                guard let self else { return }
                succeeded = true
                self.viewModel?.isSessionReady = true
                self.viewModel?.isInitializingSession = false
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
        guard succeeded else { return }
        onSessionReady?(userId)
    }

    // `sendSessionInitPing` stood here until 2026-09-27: a control message sent on every fresh
    // session so that `msgNum=0` — then the only message a session could open from — would not be
    // user content. Every message of the first flight carries the handshake header now and any of
    // them opens (`decisions/sessions-renew-by-sending.md`), so the first one may be the user's.

}
